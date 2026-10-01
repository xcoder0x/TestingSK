<#
.SYNOPSIS
    Safe post-install tune-up for dedicated Windows Server 2022 / 2025 RDP servers
    (faster reboot, safe network settings, cleanup of install/update/temp files).
    One file for both versions: the Windows build is detected automatically.

.DESCRIPTION
    VERSION DETECTION: build 20348 = Windows Server 2022, build 26100 =
    Windows Server 2025. Both are supported and get exactly the same steps,
    because every command used here behaves identically on both. On any other
    build the script stops before changing anything, unless -Force is given.

    Three sections, run one after the other, each can be skipped:

      1. Faster shutdown / reboot
         - WaitToKillServiceTimeout (machine), WaitToKillAppTimeout and
           HungAppTimeout (current user, logon screen, loaded profiles, and the
           Default profile so every NEW RDP user inherits them)
         - AutoEndTasks only with -ForceEndTasks (off by default: it can close a
           customer's unsaved work at logoff)
         - Shutdown Event Tracker off, verbose boot/shutdown status on
         - page file NOT wiped at shutdown, boot menu timeout 3 s
         - hibernate off, High Performance power plan (restored if missing)
         - Server Manager no longer auto-opens at logon

      2. Network - safe items only
         - saves a baseline of NIC / IP / route / TCP configuration
         - NIC power saving off with -NoRestart (applied at next reboot, so no
           link drop while you are connected over the IPLC line)
         - RDP keep-alives so dropped WAN sessions are detected
         - NEVER touches IP addresses, gateways, DNS, bindings, offloads, MTU,
           IPv6, firewall, Winsock, or any NIC that is not "Up"
           (the port for the future IPLC-1 line is left alone)

      3. Cleanup - only what Windows itself treats as disposable
         - DISM component store cleanup (no /ResetBase, updates stay removable)
         - Windows Update download cache (history kept), Delivery Optimization cache
         - Disk Cleanup (cleanmgr) silently with a conservative handler set
         - temp folders: system and current user older than 1 hour, other users
           older than 1 day; files in use are skipped
         - archived CBS / DISM / Windows Update logs, setup leftovers (incl.
           unattend*.xml which may hold passwords), WER queue, own Recycle Bin

    Safety:
      - shows the plan and asks you to type YES before changing anything
        (-NoPrompt for unattended runs)
      - -DryRun prints every action without doing it
      - every registry change is logged with its previous value in
        C:\ProgramData\ServerTune\<timestamp>\registry-old-values.tsv
      - full console transcript in the same folder
      - DISM / update cache steps are skipped while a servicing reboot or an
        update installation is pending
      - never reboots unless -RebootWhenDone is given

.PARAMETER DryRun
    Show what would change without changing anything.

.PARAMETER ReportOnly
    Only print hardware / NIC / last-reboot timing information. No changes.
    Run this after the reboot to see the measured reboot time.

.PARAMETER NoPrompt
    Do not ask for the YES confirmation (for unattended runs on later servers).

.PARAMETER Force
    Run even if the Windows build is not 20348 (Server 2022) or 26100 (Server 2025).

.PARAMETER ForceEndTasks
    Also set AutoEndTasks=1 for users. Faster logoff, but an app with unsaved
    work is closed without asking. Off by default on a customer RDP server.

.PARAMETER SkipRebootTweaks
    Skip section 1.

.PARAMETER SkipNetwork
    Skip section 2.

.PARAMETER SkipCleanup
    Skip section 3.

.PARAMETER RebootWhenDone
    Reboot at the end with  shutdown /r /f /t 10 . Off by default because
    customers may be connected.

.PARAMETER ServiceKillTimeoutMs
    WaitToKillServiceTimeout in ms (default 5000, minimum 5000). The script
    prints the current value before changing it. Do not go lower on a server
    that runs databases or anything that must flush on stop.

.PARAMETER AppKillTimeoutMs
    WaitToKillAppTimeout in ms (default 5000).

.PARAMETER HungAppTimeoutMs
    HungAppTimeout in ms (default 3000).

.PARAMETER BootMenuTimeoutSec
    bcdedit /timeout value in seconds (default 3).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -DryRun
    Preview only.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1
    Apply all three sections after typing YES. No reboot.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -NoPrompt -RebootWhenDone
    Unattended run on an already-verified server, forced reboot at the end.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -ReportOnly
    After the reboot: measured reboot time, NIC summary, nothing changed.

.NOTES
    Run in Windows PowerShell as Administrator on the server itself (console or
    RDP; cleanmgr needs an interactive desktop). Install pending Windows Updates
    and reboot BEFORE running the cleanup section.

    The FIRST reboot after cleanup can be slower ("Cleaning up... do not turn
    off") while the component store cleanup completes. Measure the SECOND one.
    On dedicated hardware most of the remaining reboot time is firmware POST:
    disable unused PXE / option ROMs in the BIOS and enable Fast Boot there.

    When IPLC-1 is patched to the second NIC later: give it an IP but NO second
    default gateway (two default gateways cause asymmetric routing and RDP
    drops). Add specific routes for the IPLC-1 networks instead.

    Deliberately NOT done, because it can break the IPLC link or the OS:
      netsh winsock reset / netsh int ip reset (wipe static IPs),
      Disable-/Restart-NetAdapter, Set-NetAdapterAdvancedProperty, offload or
      EEE changes (reset the link), disabling IPv6 / NetBIOS / firewall,
      TCP autotuning changes, Dism /ResetBase, deleting WinSxS,
      Windows\Installer, event logs, Prefetch, SoftwareDistribution\DataStore,
      disabling services or scheduled tasks other than Server Manager start-up.

    Rollback of the main items (old values are in registry-old-values.tsv):
      reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d <old> /f
      reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" /f
      reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v VerboseStatus /f
      reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v KeepAliveEnable /f
      reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" /v DoNotOpenAtLogon /f
      Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName ServerManager
      bcdedit /timeout 30
      powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e   (Balanced)
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$ReportOnly,
    [switch]$NoPrompt,
    [switch]$Force,
    [switch]$ForceEndTasks,
    [switch]$SkipRebootTweaks,
    [switch]$SkipNetwork,
    [switch]$SkipCleanup,
    [switch]$RebootWhenDone,
    [ValidateRange(5000, 20000)][int]$ServiceKillTimeoutMs = 5000,
    [ValidateRange(2000, 20000)][int]$AppKillTimeoutMs     = 5000,
    [ValidateRange(1000, 5000)] [int]$HungAppTimeoutMs     = 3000,
    [ValidateRange(0, 30)]      [int]$BootMenuTimeoutSec   = 3
)

$SupportedBuilds = @{ 20348 = 'Windows Server 2022'; 26100 = 'Windows Server 2025' }

$ErrorActionPreference = 'Continue'
if ($ReportOnly) { $SkipRebootTweaks = $true; $SkipNetwork = $true; $SkipCleanup = $true }

# ----------------------------------------------------------------------------
# Working folder, transcript, helpers
# ----------------------------------------------------------------------------
$script:Changes    = New-Object System.Collections.Generic.List[string]
$script:Warnings   = New-Object System.Collections.Generic.List[string]
$script:FreedBytes = [long]0
$script:Aborted    = $false
$script:Completed  = $false

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$workDir = Join-Path $env:ProgramData "ServerTune\$stamp"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$script:RollbackFile = Join-Path $workDir 'registry-old-values.tsv'
Set-Content -Path $script:RollbackFile -Value "Path`tName`tType`tOldValue"
try { Start-Transcript -Path (Join-Path $workDir 'transcript.log') -Force | Out-Null } catch { }

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
    try {
        & $Command 2>&1 | ForEach-Object { Write-Info "$_" }
        if ($LASTEXITCODE -eq 0) { Write-Done $Label; return $true }
        Write-Caution "$Label failed (exit code $LASTEXITCODE)"
    } catch {
        Write-Caution "$Label failed: $($_.Exception.Message)"
    }
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

function Test-WindowsUpdateBusy {
    try { return [bool](New-Object -ComObject Microsoft.Update.Installer).IsBusy } catch { return $false }
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
        [int]$OlderThanMinutes = 0,
        [switch]$Recurse,
        [string]$Label = $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { Write-Info "$Label - not present, skipped"; return }
    $cutoff = (Get-Date).AddMinutes(-$OlderThanMinutes)
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
    try { [long](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop).FreeSpace } catch { [long]0 }
}

try {
# ----------------------------------------------------------------------------
# 0. Pre-flight, build gate, baseline
# ----------------------------------------------------------------------------
Write-Step '0. Pre-flight'
$os = $null; $cs = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
} catch { Write-Caution "Could not read OS / hardware information: $($_.Exception.Message)" }
$build = 0
if ($os) { $build = [int]$os.BuildNumber }
Write-Info "OS        : $($os.Caption) (build $build)"
$edition = $SupportedBuilds[$build]
if ($edition) { Write-Info "Detected  : $edition - supported, identical steps on 2022 and 2025" }
else {
    $msg = "Build $build is not Windows Server 2022 (20348) or Windows Server 2025 (26100)."
    if ($Force) { $edition = "build $build (unverified)"; Write-Caution "$msg Continuing because -Force was given." }
    else {
        Write-Host "    [STOP] $msg This script was written for those two. Use -Force to override. Nothing was changed." -ForegroundColor Red
        $script:Aborted = $true
        return
    }
}
if ($cs) {
    Write-Info "Hardware  : $($cs.Manufacturer) $($cs.Model)"
    Write-Info "Hypervisor present: $($cs.HypervisorPresent)  (False = bare-metal dedicated server)"
    if ($cs.HypervisorPresent) { Write-Caution 'A hypervisor is present - this looks like a VM, not a dedicated server.' }
}
if ($os -and $os.ProductType -eq 1) { Write-Caution 'This is a client edition of Windows; the script is written for Windows Server.' }
if ($DryRun) { Write-Info 'DRY RUN - nothing will be changed.' }

try {
    $sessions = @(query user 2>$null | Select-Object -Skip 1)
    Write-Info "Logged-on sessions: $($sessions.Count)"
    if ($sessions.Count -gt 1) { Write-Caution 'Other users are logged on. A forced reboot will close their sessions.' }
} catch { Write-Info 'Logged-on sessions: (could not query)' }

try {
    $pendingAtStart = Test-PendingReboot
    if ($pendingAtStart) { Write-Caution "Reboot already pending: $($pendingAtStart -join ', ')" }
} catch { }

$freeBefore = Get-FreeBytes
Write-Info ('Free space on {0}: {1:N1} GB' -f $env:SystemDrive, ($freeBefore / 1GB))

Write-Info 'Last reboot timing (from System event log):'
$tl = Get-RebootTimeline
if ($tl) { $tl | Format-List | Out-String -Stream | Where-Object { $_.Trim() } | ForEach-Object { Write-Info "  $_" } }
else     { Write-Info '  (no complete reboot cycle found in the log yet)' }

Write-Info 'Physical NICs:'
$phys = @()
try {
    $phys = @(Get-NetAdapter -Physical -ErrorAction Stop)
    foreach ($a in $phys) {
        $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -ExpandProperty IPAddress) -join ','
        $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty NextHop) -join ','
        Write-Info ('  {0,-22} {1,-13} {2,-9} IP={3,-18} GW={4,-15} {5}' -f $a.Name, $a.Status, $a.LinkSpeed, $ip, $gw, $a.InterfaceDescription)
    }
    $gwCount = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
    if ($gwCount -gt 1) { Write-Caution "$gwCount default gateways configured. Keep ONE default gateway (IPLC-2); reach IPLC-1 networks with specific routes." }
} catch { Write-Caution "Could not list network adapters: $($_.Exception.Message)" }

if (-not $DryRun -and -not $ReportOnly -and -not $NoPrompt) {
    if (-not [Environment]::UserInteractive) {
        Write-Caution 'No interactive console and -NoPrompt not given. Nothing was changed.'
        $script:Aborted = $true
        return
    }
    Write-Host ''
    Write-Host "About to apply to $env:COMPUTERNAME ($edition):" -ForegroundColor Yellow
    if (-not $SkipRebootTweaks) { Write-Host '  1. shutdown/reboot timeouts, power plan, hibernate off, Server Manager auto-start off' }
    if (-not $SkipNetwork)      { Write-Host '  2. NIC power saving off (-NoRestart, no link drop), RDP keep-alives, DNS cache flush' }
    if (-not $SkipCleanup)      { Write-Host '  3. DISM cleanup, update caches, Disk Cleanup, temp files, old logs' }
    Write-Host '  No IP / gateway / NIC binding / firewall changes.'
    if ($RebootWhenDone) { Write-Host '  FORCED REBOOT at the end (-RebootWhenDone).' -ForegroundColor Yellow } else { Write-Host '  No reboot.' }
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') {
        Write-Host '    Cancelled. Nothing was changed.'
        $script:Aborted = $true
        return
    }
}

Write-Step "0b. Saving baseline to $workDir"
function Save-Baseline {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Body)
    try { & $Body 2>&1 | Out-File -FilePath (Join-Path $workDir $File) -ErrorAction Stop; Write-Info "saved $File" }
    catch { Write-Caution "Baseline $File not saved: $($_.Exception.Message)" }
}
Save-Baseline 'bcdedit-before.txt'            { bcdedit /enum }
Save-Baseline 'powercfg-before.txt'           { powercfg /list }
Save-Baseline 'ipconfig-all-before.txt'       { ipconfig /all }
Save-Baseline 'tcp-global-before.txt'         { netsh int tcp show global }
Save-Baseline 'routes-before.txt'             { route print }
Save-Baseline 'netadapter-before.txt'         { Get-NetAdapter -ErrorAction Stop | Format-List * }
Save-Baseline 'netipconfiguration-before.txt' { Get-NetIPConfiguration -Detailed -ErrorAction Stop }
Save-Baseline 'nic-advanced-before.txt'       { Get-NetAdapterAdvancedProperty -ErrorAction Stop | Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue | Format-Table -AutoSize }
Save-Baseline 'nic-power-before.txt'          { Get-NetAdapterPowerManagement -ErrorAction Stop | Format-List * }
Save-Baseline 'nic-bindings-before.txt'       { Get-NetAdapterBinding -ErrorAction Stop | Select-Object Name, DisplayName, ComponentID, Enabled | Format-Table -AutoSize }
Save-Baseline 'reg-hkcu-desktop.txt'          { reg query 'HKCU\Control Panel\Desktop' }
Save-Baseline 'reg-policies-windows-nt.txt'   { reg query 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT' /s }
Save-Baseline 'reg-terminal-services.txt'     { reg query 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' }

# ----------------------------------------------------------------------------
# 1. Faster shutdown / reboot
# ----------------------------------------------------------------------------
if (-not $SkipRebootTweaks) { try {
    Write-Step '1. Faster shutdown / reboot'

    Write-Info '1a. Service stop grace period'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' "$ServiceKillTimeoutMs" -Type String -Why '(ms)'

    Write-Info '1b. Application stop / hung-app timeouts: current user, logon screen, loaded profiles'
    $hives = @('HKCU:', 'HKU:\.DEFAULT')
    Get-ChildItem HKU:\ -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        ForEach-Object { $hives += "HKU:\$($_.PSChildName)" }
    foreach ($h in $hives) {
        $p = "$h\Control Panel\Desktop"
        Set-RegValue $p 'WaitToKillAppTimeout' "$AppKillTimeoutMs" -Type String -Why '(ms)'
        Set-RegValue $p 'HungAppTimeout'       "$HungAppTimeoutMs" -Type String -Why '(ms)'
        if ($ForceEndTasks) { Set-RegValue $p 'AutoEndTasks' '1' -Type String -Why '(-ForceEndTasks)' }
    }
    if (-not $ForceEndTasks) { Write-Info 'AutoEndTasks left unchanged (use -ForceEndTasks to set it; it can close unsaved customer work at logoff)' }

    Write-Info '1c. Same timeouts in the Default profile so every NEW RDP user inherits them (written with reg.exe, hive unloaded again)'
    $defHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $defHive)) { Write-Info 'Default profile hive not found, skipped' }
    elseif ($DryRun) { Write-Info "[DRYRUN] Default profile: WaitToKillAppTimeout=$AppKillTimeoutMs, HungAppTimeout=$HungAppTimeoutMs" }
    else {
        $null = & reg.exe load 'HKU\TuneDefault' $defHive 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $k = 'HKU\TuneDefault\Control Panel\Desktop'
                & reg.exe query $k 2>&1 | Where-Object { "$_" -match 'WaitToKillAppTimeout|HungAppTimeout|AutoEndTasks' } |
                    ForEach-Object { Write-Info "Default profile before: $("$_".Trim())" }
                $ok = $true
                $null = & reg.exe add $k /v WaitToKillAppTimeout /t REG_SZ /d "$AppKillTimeoutMs" /f 2>&1; if ($LASTEXITCODE -ne 0) { $ok = $false }
                $null = & reg.exe add $k /v HungAppTimeout       /t REG_SZ /d "$HungAppTimeoutMs" /f 2>&1; if ($LASTEXITCODE -ne 0) { $ok = $false }
                if ($ForceEndTasks) { $null = & reg.exe add $k /v AutoEndTasks /t REG_SZ /d 1 /f 2>&1; if ($LASTEXITCODE -ne 0) { $ok = $false } }
                if ($ok) { Write-Done "Default profile: WaitToKillAppTimeout=$AppKillTimeoutMs, HungAppTimeout=$HungAppTimeoutMs" }
                else     { Write-Caution 'Default profile: one or more reg.exe add commands failed (see transcript)' }
            } finally {
                $unloaded = $false
                for ($i = 1; $i -le 5 -and -not $unloaded; $i++) {
                    [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds (300 * $i)
                    $null = & reg.exe unload 'HKU\TuneDefault' 2>&1
                    $unloaded = ($LASTEXITCODE -eq 0)
                }
                if (-not $unloaded) { Write-Caution 'Default profile hive could not be unloaded (HKU\TuneDefault). Reboot before any NEW user logs on, otherwise they may get a temporary profile.' }
            }
        } else {
            Write-Caution 'Default profile hive could not be loaded; new users keep the default app timeouts.'
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
    $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if (((powercfg /getactivescheme) -join '') -match $hp) { Write-Info 'High Performance plan already active' }
    elseif ($DryRun) { Write-Info '[DRYRUN] powercfg /setactive High Performance' }
    else {
        $target = $hp
        if (((powercfg /list) -join "`n") -notmatch $hp) {
            Write-Info 'High Performance plan missing, restoring it from the built-in template'
            $dup = (powercfg /duplicatescheme $hp 2>&1) -join ' '
            if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $target = $Matches[1] }
            else { Write-Caution "Could not restore the High Performance plan: $dup"; $target = $null }
        }
        if ($target) { Invoke-Native "powercfg /setactive $target (High Performance)" { powercfg /setactive $target } | Out-Null }
    }

    Write-Info '1j. Server Manager must not auto-open at every logon'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' 'DoNotOpenAtLogon' 1
    $sm = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.State -ne 'Disabled') {
        if ($DryRun) { Write-Info '[DRYRUN] Disable scheduled task \Microsoft\Windows\Server Manager\ServerManager' }
        else { $sm | Disable-ScheduledTask | Out-Null; Write-Done 'Scheduled task ServerManager disabled' }
    } elseif ($sm) { Write-Info 'ServerManager task already disabled' }
} catch { Write-Caution "Section 1 stopped early: $($_.Exception.Message)" } }

# ----------------------------------------------------------------------------
# 2. Network - safe items only
# ----------------------------------------------------------------------------
if (-not $SkipNetwork) { try {
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
} catch { Write-Caution "Section 2 stopped early: $($_.Exception.Message)" } }

# ----------------------------------------------------------------------------
# 3. Cleanup
# ----------------------------------------------------------------------------
if (-not $SkipCleanup) { try {
    Write-Step '3. Cleanup'

    $pending = Test-PendingReboot
    $cbsBusy = @($pending | Where-Object { $_ -ne 'PendingFileRenameOperations' })
    $wuBusy  = Test-WindowsUpdateBusy
    if ($cbsBusy.Count) { Write-Caution "Servicing reboot pending ($($cbsBusy -join ', ')). DISM and update-cache steps skipped: reboot, then re-run with -SkipRebootTweaks -SkipNetwork." }
    if ($wuBusy)        { Write-Caution 'Windows Update is installing right now. DISM and update-cache steps skipped: let it finish, reboot, then re-run with -SkipRebootTweaks -SkipNetwork.' }
    $servicingOk = (-not $cbsBusy.Count) -and (-not $wuBusy)
    if ($freeBefore -gt 0 -and ($freeBefore / 1GB) -lt 3) { Write-Caution 'Less than 3 GB free; DISM may need scratch space. Watch for errors.' }

    Write-Info '3a. DISM component store cleanup (5-20 min, do not interrupt; no /ResetBase so updates stay uninstallable)'
    if ($servicingOk) {
        if ($DryRun) { Write-Info '[DRYRUN] Dism /Online /Cleanup-Image /StartComponentCleanup' }
        else {
            try {
                & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart
                if ($LASTEXITCODE -eq 0) { Write-Done 'DISM StartComponentCleanup' }
                else { Write-Caution "DISM StartComponentCleanup exit code $LASTEXITCODE (see $env:SystemRoot\Logs\DISM\dism.log)" }
            } catch { Write-Caution "DISM could not be started: $($_.Exception.Message)" }
        }
    }

    Write-Info '3b. Windows Update download cache (SoftwareDistribution\Download only - update history is kept)'
    if ($servicingOk) {
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
    if (-not (Test-Path -LiteralPath $cleanmgr)) { Write-Info 'cleanmgr.exe not present (Server Core?), skipped' }
    elseif (-not [Environment]::UserInteractive) { Write-Caution 'No interactive desktop; cleanmgr skipped (run it from a console/RDP session).' }
    else {
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
            $proc = $null
            try { $proc = Start-Process -FilePath $cleanmgr -ArgumentList '/sagerun:64' -PassThru -ErrorAction Stop }
            catch { Write-Caution "cleanmgr could not be started: $($_.Exception.Message)" }
            if ($proc) {
                if ($proc.WaitForExit(1800000)) { Write-Done 'Disk Cleanup finished' }
                else { Write-Caution 'Disk Cleanup still running after 30 min; left running, continuing.' }
            }
            foreach ($k in Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $k.PSPath -Name $flag -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Info '3e. Temp folders (system and current user: older than 1 hour; other users: older than 1 day)'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'Temp') -Recurse -OlderThanMinutes 60 -Label 'Windows\Temp'
    if ($env:TEMP) { Remove-OldFiles -Path $env:TEMP -Recurse -OlderThanMinutes 60 -Label "Current user temp ($env:TEMP)" }
    Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Join-Path $_.FullName 'AppData\Local\Temp'
        if ((Test-Path -LiteralPath $t) -and ($env:TEMP -notlike "$t*")) {
            Remove-OldFiles -Path $t -Recurse -OlderThanMinutes 1440 -Label "Temp of user $($_.Name) (>1 day old)"
        }
    }

    Write-Info '3f. Setup / servicing leftovers and archived logs'
    $logs = Join-Path $env:SystemRoot 'Logs'
    Remove-OldFiles -Path (Join-Path $logs 'CBS')           -Filter 'CbsPersist_*'                        -Label 'CBS archived logs'
    Remove-OldFiles -Path (Join-Path $logs 'DISM')          -OlderThanMinutes 1440                        -Label 'DISM old logs'
    Remove-OldFiles -Path (Join-Path $logs 'WindowsUpdate') -Filter '*.etl' -OlderThanMinutes 10080       -Label 'Windows Update ETL logs (>7 days)'
    Remove-OldFiles -Path (Join-Path $logs 'MoSetup')       -Recurse                                      -Label 'MoSetup (upgrade) logs'
    $panther = Join-Path $env:SystemRoot 'Panther'
    Remove-OldFiles -Path $panther -Filter '*.log'                                                        -Label 'Setup logs (Panther)'
    Remove-OldFiles -Path $panther -Filter 'unattend*.xml'                                                -Label 'Setup answer files (Panther - may contain passwords)'
    Remove-OldFiles -Path (Join-Path $panther 'UnattendGC') -Recurse                                      -Label 'Panther\UnattendGC'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'System32\Sysprep\Panther') -Recurse                 -Label 'Sysprep logs'
    Remove-OldFiles -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')   -Recurse     -Label 'WER report queue'
    Remove-OldFiles -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') -Recurse     -Label 'WER report archive'
    Remove-OldFiles -Path (Join-Path $env:SystemRoot 'Minidump')                                          -Label 'Minidumps'

    Write-Info '3g. Recycle Bin (current user only)'
    if ($DryRun) { Write-Info '[DRYRUN] Clear-RecycleBin -Force' }
    else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Done 'Recycle Bin emptied (current user)' }
} catch { Write-Caution "Section 3 stopped early: $($_.Exception.Message)" } }

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
    Write-Info "  2. After reboot run:  .\Optimize-RdpServer.ps1 -ReportOnly   to see the measured reboot time."
}
$script:Completed = $true
} catch {
    Write-Caution "Unexpected error, script stopped early: $($_.Exception.Message)"
    Write-Host "    Log: $workDir" -ForegroundColor Yellow
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}

if ($RebootWhenDone -and $script:Completed -and -not $DryRun -and -not $ReportOnly -and -not $script:Aborted) {
    Write-Host 'Rebooting in 10 seconds (shutdown /r /f /t 10)...' -ForegroundColor Yellow
    shutdown.exe /r /f /t 10 /c 'ServerTune: reboot after tune-up'
}
