<#
.SYNOPSIS
    Safe post-install tune-up for Windows Server 2022 / 2025 RDP servers
    (dedicated hardware, customers connect over RDP).

.DESCRIPTION
    Runs three groups of changes, one after the other, logging everything:

      1. Faster shutdown / reboot
         - service and application stop timeouts (HKLM + current user + .DEFAULT
           + Default profile, so every new RDP user inherits them)
         - Shutdown Event Tracker off, verbose boot/shutdown status on
         - page file NOT wiped at shutdown, boot menu timeout 3 s
         - hibernate off, High Performance power plan
         - Server Manager no longer auto-opens at logon

      2. Network - safe items only
         - saves a full baseline of the current NIC / IP / route / TCP config
         - turns NIC power saving off with -NoRestart (applies at next reboot,
           so NO link drop while you are connected over the IPLC)
         - RDP keep-alives so dead WAN sessions are detected
         - NEVER touches IP addresses, gateways, bindings, offloads, MTU,
           IPv6, firewall, Winsock, or any NIC that is not "Up"
           (the port for the future IPLC-1 line is left alone)

      3. Cleanup (only things Windows itself considers disposable)
         - DISM component store cleanup (no /ResetBase)
         - Windows Update download cache, Delivery Optimization cache
         - Disk Cleanup (cleanmgr) silently, with a conservative handler set
         - temp folders (other users: only files older than 1 day)
         - archived CBS / DISM / Windows Update logs, setup leftovers,
           Windows Error Reporting queue, current user's Recycle Bin

    Every registry change is logged with its previous value in
    C:\ProgramData\ServerTune\<timestamp>\registry-old-values.tsv and the
    full console output is in transcript.log in the same folder.

    Nothing in this script reboots the server unless -RebootWhenDone is given.

.PARAMETER DryRun
    Show what would change without changing anything.

.PARAMETER ReportOnly
    Only print hardware / NIC / last-reboot timing information. No changes.

.PARAMETER SkipRebootTweaks
.PARAMETER SkipNetwork
.PARAMETER SkipCleanup
    Skip the corresponding section.

.PARAMETER RebootWhenDone
    Reboot at the end with  shutdown /r /f /t 10 . Off by default because
    customers may be connected.

.PARAMETER ServiceKillTimeoutMs
    WaitToKillServiceTimeout. Server default 20000. Do not go below 5000 on a
    server that runs databases or other services that must flush on stop.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -ReportOnly
    (run this after the reboot to see the measured reboot time)
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$ReportOnly,
    [switch]$SkipRebootTweaks,
    [switch]$SkipNetwork,
    [switch]$SkipCleanup,
    [switch]$RebootWhenDone,
    [ValidateRange(5000, 20000)][int]$ServiceKillTimeoutMs = 5000,
    [ValidateRange(2000, 20000)][int]$AppKillTimeoutMs     = 5000,
    [ValidateRange(1000, 5000)] [int]$HungAppTimeoutMs     = 3000,
    [ValidateRange(0, 30)]      [int]$BootMenuTimeoutSec   = 3
)

$ErrorActionPreference = 'Continue'
if ($ReportOnly) { $SkipRebootTweaks = $true; $SkipNetwork = $true; $SkipCleanup = $true }

# ----------------------------------------------------------------------------
# Working folder, transcript, helpers
# ----------------------------------------------------------------------------
$script:Changes    = New-Object System.Collections.Generic.List[string]
$script:Warnings   = New-Object System.Collections.Generic.List[string]
$script:FreedBytes = [long]0

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$workDir = Join-Path $env:ProgramData "ServerTune\$stamp"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$script:RollbackFile = Join-Path $workDir 'registry-old-values.tsv'
Set-Content -Path $script:RollbackFile -Value "Path`tName`tType`tOldValue"
Start-Transcript -Path (Join-Path $workDir 'transcript.log') -Force | Out-Null

if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null
}

function Write-Step    ([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Info    ([string]$Text) { Write-Host "    $Text" }
function Write-Done    ([string]$Text) { Write-Host "    [OK]   $Text" -ForegroundColor Green;  $script:Changes.Add($Text) }
function Write-Caution ([string]$Text) { Write-Host "    [WARN] $Text" -ForegroundColor Yellow; $script:Warnings.Add($Text) }

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('String', 'DWord', 'QWord', 'ExpandString')][string]$Type = 'DWord',
        [string]$Why = ''
    )
    $old = $null
    if (Test-Path -LiteralPath $Path) {
        $old = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }
    if ($null -ne $old -and "$old" -eq "$Value") {
        Write-Info "$Path\$Name already = $Value"
        return
    }
    $oldText = if ($null -eq $old) { '<not set>' } else { "$old" }
    if ($DryRun) {
        Write-Info "[DRYRUN] $Path\$Name : $oldText -> $Value $Why"
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Add-Content -Path $script:RollbackFile -Value "$Path`t$Name`t$Type`t$oldText"
        Write-Done "$Path\$Name : $oldText -> $Value $Why"
    } catch {
        Write-Caution "$Path\$Name could not be set: $($_.Exception.Message)"
    }
}

function Invoke-Native {
    # Runs an external command unless -DryRun; returns $true on exit code 0.
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][scriptblock]$Command)
    if ($DryRun) { Write-Info "[DRYRUN] $Label"; return $true }
    & $Command 2>&1 | ForEach-Object { Write-Info "$_" }
    if ($LASTEXITCODE -eq 0) { Write-Done $Label; return $true }
    Write-Caution "$Label failed (exit code $LASTEXITCODE)"
    return $false
}

function Test-PendingReboot {
    $reasons = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate RebootRequired' }
    $pfr = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) { $reasons += 'PendingFileRenameOperations' }
    return $reasons
}

function Get-RebootTimeline {
    # System log: 1074 = shutdown requested, 13 = kernel shutting down,
    # 12 = kernel started, 6005 = Event Log service started (services phase done)
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 12, 13, 1074, 6005 } -MaxEvents 400 -ErrorAction Stop |
              Sort-Object TimeCreated
    } catch { return $null }
    $start = $ev | Where-Object { $_.Id -eq 12 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-General' } | Select-Object -Last 1
    if (-not $start) { return $null }
    $before = $ev | Where-Object { $_.TimeCreated -lt $start.TimeCreated }
    $req    = $before | Where-Object { $_.Id -eq 1074 } | Select-Object -Last 1
    $down   = $before | Where-Object { $_.Id -eq 13 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-General' } | Select-Object -Last 1
    $up     = $ev | Where-Object { $_.Id -eq 6005 -and $_.TimeCreated -ge $start.TimeCreated } | Select-Object -First 1
    $sec = { param($a, $b) if ($a -and $b) { [math]::Round(($b.TimeCreated - $a.TimeCreated).TotalSeconds, 1) } else { $null } }
    [pscustomobject]@{
        ShutdownRequested    = if ($req)  { $req.TimeCreated }  else { $null }
        KernelShutdown       = if ($down) { $down.TimeCreated } else { $null }
        KernelStarted        = $start.TimeCreated
        ServicesUp           = if ($up)   { $up.TimeCreated }   else { $null }
        ShutdownPhaseSeconds = & $sec $req  $down
        OfflineSeconds       = & $sec $down $start   # firmware POST + Windows boot to kernel
        BootToServicesSec    = & $sec $start $up
        TotalRebootSeconds   = & $sec $req  $up
    }
}

function Remove-OldFiles {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [int]$OlderThanDays = 0,
        [switch]$Recurse,
        [string]$Label = $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { Write-Info "$Label - not present, skipped"; return }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $items  = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -Recurse:$Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff })
    $bytes  = ($items | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    if ($items.Count -eq 0) { Write-Info "$Label - nothing to remove"; return }
    if ($DryRun) {
        Write-Info ('[DRYRUN] {0}: {1} files, {2:N1} MB would be removed' -f $Label, $items.Count, ($bytes / 1MB))
        return
    }
    $removed = 0; $freed = [long]0
    foreach ($f in $items) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++; $freed += $f.Length } catch { }
    }
    if ($Recurse) {
        Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }
    $script:FreedBytes += $freed
    Write-Done ('{0}: removed {1}/{2} files, {3:N1} MB (files in use are skipped)' -f $Label, $removed, $items.Count, ($freed / 1MB))
}

function Get-FreeBytes {
    (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
}

try {
# ----------------------------------------------------------------------------
# 0. Pre-flight and baseline
# ----------------------------------------------------------------------------
Write-Step '0. Pre-flight'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Write-Info "OS        : $($os.Caption) (build $($os.BuildNumber))"
$verName = switch ([int]$os.BuildNumber) { 20348 { 'Windows Server 2022' } 26100 { 'Windows Server 2025' } default { $null } }
if ($verName) { Write-Info "Detected  : $verName - supported; identical steps apply on 2022 and 2025" }
else { Write-Caution "Build $($os.BuildNumber) is not Server 2022 (20348) or Server 2025 (26100). Script was written for those two; review before continuing." }
Write-Info "Hardware  : $($cs.Manufacturer) $($cs.Model)"
Write-Info "Hypervisor present: $($cs.HypervisorPresent)  (False = bare-metal dedicated server)"
if ($cs.HypervisorPresent) { Write-Caution 'A hypervisor is present - this looks like a VM, not a dedicated server.' }
if ($os.ProductType -eq 1) { Write-Caution 'This is a client edition of Windows; the script is written for Windows Server.' }
if ($DryRun) { Write-Info 'DRY RUN - nothing will be changed.' }

$sessions = @(query user 2>$null | Select-Object -Skip 1)
Write-Info "Logged-on sessions: $($sessions.Count)"
if ($sessions.Count -gt 1) { Write-Caution 'Other users are logged on. A forced reboot will close their sessions.' }

$pendingAtStart = Test-PendingReboot
if ($pendingAtStart) { Write-Caution "Reboot already pending: $($pendingAtStart -join ', ')" }

$freeBefore = Get-FreeBytes
Write-Info ('Free space on {0}: {1:N1} GB' -f $env:SystemDrive, ($freeBefore / 1GB))

Write-Info 'Last reboot timing (from System event log):'
$tl = Get-RebootTimeline
if ($tl) { $tl | Format-List | Out-String -Stream | Where-Object { $_.Trim() } | ForEach-Object { Write-Info "  $_" } }
else     { Write-Info '  (no complete reboot cycle found in the log yet)' }

Write-Step "0b. Saving baseline to $workDir"
try {
    bcdedit /enum                     | Out-File (Join-Path $workDir 'bcdedit-before.txt')
    powercfg /list                    | Out-File (Join-Path $workDir 'powercfg-before.txt')
    ipconfig /all                     | Out-File (Join-Path $workDir 'ipconfig-all-before.txt')
    netsh int tcp show global         | Out-File (Join-Path $workDir 'tcp-global-before.txt')
    route print                       | Out-File (Join-Path $workDir 'routes-before.txt')
    Get-NetAdapter -ErrorAction SilentlyContinue | Format-List * | Out-File (Join-Path $workDir 'netadapter-before.txt')
    Get-NetIPConfiguration -Detailed -ErrorAction SilentlyContinue | Out-File (Join-Path $workDir 'netipconfiguration-before.txt')
    Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue |
        Export-Csv (Join-Path $workDir 'nic-advanced-before.csv') -NoTypeInformation
    Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue | Format-List * | Out-File (Join-Path $workDir 'nic-power-before.txt')
    Get-NetAdapterBinding -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, ComponentID, Enabled |
        Export-Csv (Join-Path $workDir 'nic-bindings-before.csv') -NoTypeInformation
    reg export 'HKCU\Control Panel\Desktop' (Join-Path $workDir 'reg-hkcu-desktop.reg') /y | Out-Null
    reg export 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT' (Join-Path $workDir 'reg-policies-windows-nt.reg') /y 2>$null | Out-Null
    Write-Info 'Baseline saved.'
} catch {
    Write-Caution "Baseline export problem: $($_.Exception.Message)"
}

Write-Info 'Physical NICs:'
$phys = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
foreach ($a in $phys) {
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -ExpandProperty IPAddress) -join ','
    $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty NextHop) -join ','
    Write-Info ('  {0,-22} {1,-13} {2,-9} IP={3,-18} GW={4,-15} {5}' -f $a.Name, $a.Status, $a.LinkSpeed, $ip, $gw, $a.InterfaceDescription)
}
$gwCount = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
if ($gwCount -gt 1) { Write-Caution "$gwCount default gateways configured. Keep ONE default gateway (IPLC-2); reach IPLC-1 networks with specific routes." }

# ----------------------------------------------------------------------------
# 1. Faster shutdown / reboot
# ----------------------------------------------------------------------------
if (-not $SkipRebootTweaks) {
    Write-Step '1. Faster shutdown / reboot'

    Write-Info '1a. Service stop grace period (Server default 20000 ms)'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' "$ServiceKillTimeoutMs" -Type String

    Write-Info '1b. Application stop / hung-app timeouts for current user, logon screen and all loaded profiles'
    $hives = @('HKCU:', 'HKU:\.DEFAULT')
    Get-ChildItem HKU:\ -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        ForEach-Object { $hives += "HKU:\$($_.PSChildName)" }
    foreach ($h in $hives) {
        $p = "$h\Control Panel\Desktop"
        Set-RegValue $p 'WaitToKillAppTimeout' "$AppKillTimeoutMs" -Type String
        Set-RegValue $p 'HungAppTimeout'       "$HungAppTimeoutMs" -Type String
        Set-RegValue $p 'AutoEndTasks'         '1'                 -Type String -Why '(no "program not responding" wait at logoff)'
    }

    Write-Info '1c. Same timeouts in the Default profile so every NEW RDP user inherits them'
    $defHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $defHive) {
        $null = & reg.exe load 'HKU\TuneDefault' $defHive 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $p = 'HKU:\TuneDefault\Control Panel\Desktop'
                Set-RegValue $p 'WaitToKillAppTimeout' "$AppKillTimeoutMs" -Type String
                Set-RegValue $p 'HungAppTimeout'       "$HungAppTimeoutMs" -Type String
                Set-RegValue $p 'AutoEndTasks'         '1'                 -Type String
            } finally {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
                $null = & reg.exe unload 'HKU\TuneDefault' 2>&1
                if ($LASTEXITCODE -ne 0) { Write-Caution 'Default profile hive is still loaded (HKU\TuneDefault). It is released at reboot; harmless.' }
            }
        } else {
            Write-Caution 'Could not load the Default profile hive; new users keep the default app timeouts.'
        }
    }

    Write-Info '1d. Shutdown Event Tracker (the "why are you shutting down" dialog) off'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonOn' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonUI' 0

    Write-Info '1e. Verbose boot/shutdown status (shows which phase is slow)'
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1

    Write-Info '1f. Do not wipe the page file at shutdown'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 0

    Write-Info "1g. Boot menu timeout -> $BootMenuTimeoutSec s"
    Invoke-Native "bcdedit /timeout $BootMenuTimeoutSec" { bcdedit /timeout $BootMenuTimeoutSec } | Out-Null

    Write-Info '1h. Hibernate off (removes hiberfil.sys, no hybrid shutdown)'
    Invoke-Native 'powercfg /hibernate off' { powercfg /hibernate off } | Out-Null

    Write-Info '1i. High Performance power plan (CPU, PCIe and NIC stay out of power-saving states)'
    $active = (powercfg /getactivescheme) -join ''
    if ($active -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { Write-Info 'High Performance plan already active' }
    else { Invoke-Native 'powercfg /setactive High Performance' { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c } | Out-Null }

    Write-Info '1j. Server Manager must not auto-open at every logon'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' 'DoNotOpenAtLogon' 1
    $sm = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.State -ne 'Disabled') {
        if ($DryRun) { Write-Info '[DRYRUN] Disable scheduled task \Microsoft\Windows\Server Manager\ServerManager' }
        else { $sm | Disable-ScheduledTask | Out-Null; Write-Done 'Scheduled task ServerManager disabled' }
    } elseif ($sm) { Write-Info 'ServerManager task already disabled' }
}

# ----------------------------------------------------------------------------
# 2. Network - safe items only
# ----------------------------------------------------------------------------
if (-not $SkipNetwork) {
    Write-Step '2. Network (no IP / gateway / binding / offload changes)'

    $up   = @($phys | Where-Object { $_.Status -eq 'Up' })
    $down = @($phys | Where-Object { $_.Status -ne 'Up' })
    if ($down.Count) { Write-Info "Left untouched (not Up, e.g. the future IPLC-1 port): $(($down | ForEach-Object Name) -join ', ')" }

    Write-Info '2a. NIC power saving off on connected NICs (-NoRestart: applied at next reboot, no link drop now)'
    $setCmd = Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue
    if (-not $setCmd) {
        Write-Caution 'Set-NetAdapterPowerManagement not available; skipped.'
    } elseif (-not $setCmd.Parameters.ContainsKey('NoRestart')) {
        Write-Caution 'Set-NetAdapterPowerManagement has no -NoRestart here; skipped to avoid a link reset. Do it in Device Manager during a maintenance window.'
    } else {
        foreach ($a in $up) {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            if (-not $pm) { Write-Info "NIC '$($a.Name)': no power management info"; continue }
            $params = @{}
            foreach ($prop in 'AllowComputerToTurnOffDevice', 'DeviceSleepOnDisconnect', 'SelectiveSuspend') {
                if ($setCmd.Parameters.ContainsKey($prop) -and "$($pm.$prop)" -eq 'Enabled') { $params[$prop] = 'Disabled' }
            }
            if ($params.Count -eq 0) { Write-Info "NIC '$($a.Name)': power saving already off / unsupported"; continue }
            if ($DryRun) { Write-Info "[DRYRUN] NIC '$($a.Name)': $($params.Keys -join ', ') -> Disabled"; continue }
            try {
                Set-NetAdapterPowerManagement -Name $a.Name @params -NoRestart -ErrorAction Stop
                Write-Done "NIC '$($a.Name)': $($params.Keys -join ', ') -> Disabled (effective after reboot)"
            } catch {
                Write-Caution "NIC '$($a.Name)': power management not changed - $($_.Exception.Message)"
            }
        }
    }

    Write-Info '2b. RDP keep-alives (detect dropped WAN sessions, keep firewall/NAT state alive)'
    $ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    Set-RegValue $ts 'KeepAliveEnable'   1
    Set-RegValue $ts 'KeepAliveInterval' 1 -Why '(minutes)'

    Write-Info '2c. DNS resolver cache flush'
    Invoke-Native 'ipconfig /flushdns' { ipconfig /flushdns } | Out-Null
}

# ----------------------------------------------------------------------------
# 3. Cleanup
# ----------------------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Step '3. Cleanup'

    $pending = Test-PendingReboot
    $cbsBusy = @($pending | Where-Object { $_ -ne 'PendingFileRenameOperations' })
    if ($cbsBusy.Count) {
        Write-Caution "Servicing reboot pending ($($cbsBusy -join ', ')). DISM and Windows Update cache steps are skipped - reboot, then re-run with -SkipRebootTweaks -SkipNetwork."
    }

    Write-Info '3a. DISM component store cleanup (5-20 min, do not interrupt; no /ResetBase so updates stay uninstallable)'
    if (-not $cbsBusy.Count) {
        if ($DryRun) { Write-Info '[DRYRUN] Dism /Online /Cleanup-Image /StartComponentCleanup' }
        else {
            & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart
            if ($LASTEXITCODE -eq 0) { Write-Done 'DISM StartComponentCleanup' }
            else { Write-Caution "DISM StartComponentCleanup exit code $LASTEXITCODE (see $env:SystemRoot\Logs\DISM\dism.log)" }
        }
    }

    Write-Info '3b. Windows Update download cache (SoftwareDistribution\Download only - update history is kept)'
    if (-not $cbsBusy.Count) {
        $wuWasRunning   = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running'
        $bitsWasRunning = (Get-Service bits     -ErrorAction SilentlyContinue).Status -eq 'Running'
        if (-not $DryRun) { Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue }
        Remove-OldFiles -Path (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Recurse -Label 'Windows Update download cache'
        if (-not $DryRun) {
            if ($bitsWasRunning) { Start-Service bits     -ErrorAction SilentlyContinue }
            if ($wuWasRunning)   { Start-Service wuauserv -ErrorAction SilentlyContinue }
        }
    }

    Write-Info '3c. Delivery Optimization cache'
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        if ($DryRun) { Write-Info '[DRYRUN] Delete-DeliveryOptimizationCache -Force' }
        else {
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Write-Done 'Delivery Optimization cache cleared' }
            catch { Write-Caution "Delivery Optimization cache: $($_.Exception.Message)" }
        }
    } else { Write-Info 'Delete-DeliveryOptimizationCache not available, skipped' }

    Write-Info '3d. Disk Cleanup (cleanmgr) silently with a conservative handler set'
    $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
    if (Test-Path -LiteralPath $cleanmgr) {
        # Deliberately NOT included: Device Driver Packages, Recycle Bin, Windows Defender,
        # Windows ESD installation files, Language Pack, User file versions.
        $handlers = @(
            'Active Setup Temp Folders', 'D3D Shader Cache', 'Delivery Optimization Files',
            'Downloaded Program Files', 'Internet Cache Files', 'Old ChkDsk Files',
            'Previous Installations', 'Setup Log Files', 'System error memory dump files',
            'System error minidump files', 'Temporary Files', 'Temporary Setup Files',
            'Thumbnail Cache', 'Update Cleanup', 'Upgrade Discarded Files',
            'Windows Error Reporting Files', 'Windows Upgrade Log Files'
        )
        $vc   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        $flag = 'StateFlags0064'
        $selected = @()
        foreach ($k in Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue) {
            $on = $handlers -contains $k.PSChildName
            if ($on) { $selected += $k.PSChildName }
            if ($DryRun) { continue }
            if ($on) { Set-ItemProperty -LiteralPath $k.PSPath -Name $flag -Value 2 -Type DWord -ErrorAction SilentlyContinue }
            else     { Remove-ItemProperty -LiteralPath $k.PSPath -Name $flag -ErrorAction SilentlyContinue }
        }
        Write-Info "Handlers: $($selected -join ', ')"
        if ($DryRun) { Write-Info '[DRYRUN] cleanmgr /sagerun:64' }
        else {
            $proc = Start-Process -FilePath $cleanmgr -ArgumentList '/sagerun:64' -PassThru
            if ($proc.WaitForExit(1800000)) { Write-Done 'Disk Cleanup finished' }
            else { Write-Caution 'Disk Cleanup still running after 30 min; left running, continuing.' }
            foreach ($k in Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $k.PSPath -Name $flag -ErrorAction SilentlyContinue
            }
        }
    } else { Write-Info 'cleanmgr.exe not present (Server Core?), skipped' }

    Write-Info '3e. Temp folders'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'Temp') -Recurse -Label 'Windows\Temp'
    Remove-OldFiles -Path $env:TEMP -Recurse -Label "Current user temp ($env:TEMP)"
    Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Join-Path $_.FullName 'AppData\Local\Temp'
        if ((Test-Path -LiteralPath $t) -and ($env:TEMP -notlike "$t*")) {
            # other profiles: only files untouched for more than a day, so live RDP sessions are not disturbed
            Remove-OldFiles -Path $t -Recurse -OlderThanDays 1 -Label "Temp of user $($_.Name) (>1 day old)"
        }
    }

    Write-Info '3f. Setup / servicing leftovers and archived logs'
    $logs = Join-Path $env:SystemRoot 'Logs'
    Remove-OldFiles -Path (Join-Path $logs 'CBS')           -Filter 'CbsPersist_*' -Label 'CBS archived logs'
    Remove-OldFiles -Path (Join-Path $logs 'DISM')          -OlderThanDays 1       -Label 'DISM old logs'
    Remove-OldFiles -Path (Join-Path $logs 'WindowsUpdate') -Filter '*.etl' -OlderThanDays 7 -Label 'Windows Update ETL logs (>7 days)'
    Remove-OldFiles -Path (Join-Path $logs 'MoSetup')       -Recurse               -Label 'MoSetup (upgrade) logs'
    $panther = Join-Path $env:SystemRoot 'Panther'
    Remove-OldFiles -Path $panther -Filter '*.log'          -Label 'Setup logs (Panther)'
    Remove-OldFiles -Path $panther -Filter 'unattend*.xml'  -Label 'Setup answer files (Panther - may contain passwords)'
    Remove-OldFiles -Path (Join-Path $panther 'UnattendGC') -Recurse -Label 'Panther\UnattendGC'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'System32\Sysprep\Panther') -Recurse -Label 'Sysprep logs'
    Remove-OldFiles -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')   -Recurse -Label 'WER report queue'
    Remove-OldFiles -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') -Recurse -Label 'WER report archive'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'Minidump') -Label 'Minidumps'

    Write-Info '3g. Recycle Bin (current user)'
    if ($DryRun) { Write-Info '[DRYRUN] Clear-RecycleBin -Force' }
    else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Done 'Recycle Bin emptied (current user)' }
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Step 'Summary'
$freeAfter = Get-FreeBytes
Write-Info ('Free space on {0}: {1:N1} GB -> {2:N1} GB' -f $env:SystemDrive, ($freeBefore / 1GB), ($freeAfter / 1GB))
Write-Info "Changes applied: $($script:Changes.Count)"
if ($script:Warnings.Count) {
    Write-Info "Warnings: $($script:Warnings.Count)"
    $script:Warnings | ForEach-Object { Write-Info "  - $_" }
}
Write-Info "Log, baseline and registry old values: $workDir"
if (-not $ReportOnly) {
    Write-Info ''
    Write-Info 'Next steps:'
    Write-Info '  1. Reboot:            shutdown /r /f /t 0'
    Write-Info '     The FIRST reboot after cleanup can be slower ("Cleaning up... do not turn off") - that is the'
    Write-Info '     component cleanup finishing. Measure the SECOND reboot.'
    Write-Info '  2. After reboot run:  .\Optimize-RdpServer.ps1 -ReportOnly   to see the measured reboot time.'
}
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}

if ($RebootWhenDone -and -not $DryRun -and -not $ReportOnly) {
    Write-Host 'Rebooting in 10 seconds (shutdown /r /f /t 10)...' -ForegroundColor Yellow
    shutdown.exe /r /f /t 10 /c 'ServerTune: reboot after tune-up'
}
