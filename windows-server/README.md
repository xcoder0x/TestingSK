# Windows Server 2022 / 2025 RDP server tune-up

Safe, reversible post-install tuning for dedicated RDP servers:

1. faster shutdown / reboot
2. network: baseline + safe NIC/RDP settings only (nothing that can drop the IPLC link)
3. cleanup of installation cache, update cache, logs and temp files

Files:

| File | Purpose |
|------|---------|
| `Optimize-RdpServer.ps1` | Combined script. Runs the same steps as the manual commands below, one after the other, with logging, dry-run and rollback data. |
| `README.md` | This runbook: the manual commands for the first server, differences 2022 vs 2025, what is deliberately NOT done, rollback. |

## Works on both Server 2022 and Server 2025

One script covers both. Every command below exists and behaves the same on
Windows Server 2022 (build 20348) and Windows Server 2025 (build 26100).
The script detects the build and prints which one it found. What differs:

| Topic | Server 2022 | Server 2025 |
|-------|-------------|-------------|
| Registry keys used here (timeouts, Shutdown Event Tracker, RDP keep-alive, Server Manager) | same | same |
| `cleanmgr.exe` and its `VolumeCaches` handlers | present (Desktop Experience) | present (Desktop Experience) |
| `Dism /StartComponentCleanup` | yes | yes (2025 uses checkpoint cumulative updates, cleanup still applies) |
| `Delete-DeliveryOptimizationCache` | yes | yes |
| `Set-NetAdapterPowerManagement -NoRestart` | yes | yes |
| Default power plan | Balanced | Balanced |
| Hibernate | off by default (command is a no-op, harmless) | off by default |
| Windows PowerShell 5.1 | default shell | default shell (PowerShell 7 not preinstalled) |

If the script sees any other build it prints a warning and continues, so review before trusting it on, for example, Server 2019.

## Before you start (first server, manual run)

- Open **Windows PowerShell as Administrator** (not ISE, not a remote PowerShell session: `cleanmgr` needs an interactive desktop).
- Ideally be on the server's **iDRAC / iLO / IPMI console** rather than RDP for the first run. Nothing below touches IPs or NICs live, but a console is cheap insurance.
- Install pending Windows Updates and reboot **before** step 3; DISM refuses to clean while a servicing reboot is pending.
- Timeouts are strings (`REG_SZ`) on purpose: that is how Windows stores them.

## Step 0: baseline and current reboot time

```powershell
New-Item -ItemType Directory -Force C:\ProgramData\ServerTune\manual | Out-Null
bcdedit /enum              | Out-File C:\ProgramData\ServerTune\manual\bcdedit-before.txt
powercfg /list             | Out-File C:\ProgramData\ServerTune\manual\powercfg-before.txt
ipconfig /all              | Out-File C:\ProgramData\ServerTune\manual\ipconfig-before.txt
netsh int tcp show global  | Out-File C:\ProgramData\ServerTune\manual\tcp-global-before.txt
route print                | Out-File C:\ProgramData\ServerTune\manual\routes-before.txt
Get-NetAdapterAdvancedProperty | Select-Object Name, DisplayName, DisplayValue | Export-Csv C:\ProgramData\ServerTune\manual\nic-advanced-before.csv -NoTypeInformation
Get-NetAdapterPowerManagement  | Format-List * | Out-File C:\ProgramData\ServerTune\manual\nic-power-before.txt
reg export "HKCU\Control Panel\Desktop" C:\ProgramData\ServerTune\manual\hkcu-desktop.reg /y
```

Confirm it is bare metal and see the NICs (the port for the future IPLC-1 line will show `Disconnected`; leave it alone):

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, HypervisorPresent
Get-NetAdapter -Physical | Format-Table Name, Status, LinkSpeed, MacAddress, InterfaceDescription -AutoSize
Get-NetIPConfiguration | Format-Table InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer -AutoSize
```

Last reboot timing from the System log (1074 = reboot requested, 13 = kernel shutting down, 12 = kernel started, 6005 = services up):

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=12,13,1074,6005} -MaxEvents 20 | Sort-Object TimeCreated | Format-Table TimeCreated, Id, ProviderName -AutoSize
```

## Step 1: faster shutdown / reboot

Service stop grace period (check the current value first; Windows records it as a string):

```powershell
reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout
reg add   "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d 5000 /f
```

Application timeouts for the current admin user:

```powershell
reg add "HKCU\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 5000 /f
reg add "HKCU\Control Panel\Desktop" /v HungAppTimeout       /t REG_SZ /d 3000 /f
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks         /t REG_SZ /d 1    /f
```

Same for the logon screen / SYSTEM desktop:

```powershell
reg add "HKU\.DEFAULT\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 5000 /f
reg add "HKU\.DEFAULT\Control Panel\Desktop" /v HungAppTimeout       /t REG_SZ /d 3000 /f
reg add "HKU\.DEFAULT\Control Panel\Desktop" /v AutoEndTasks         /t REG_SZ /d 1    /f
```

Same in the Default profile so every **new** RDP customer inherits it:

```powershell
reg load "HKU\DefUser" C:\Users\Default\NTUSER.DAT
reg add  "HKU\DefUser\Control Panel\Desktop" /v WaitToKillAppTimeout /t REG_SZ /d 5000 /f
reg add  "HKU\DefUser\Control Panel\Desktop" /v HungAppTimeout       /t REG_SZ /d 3000 /f
reg add  "HKU\DefUser\Control Panel\Desktop" /v AutoEndTasks         /t REG_SZ /d 1    /f
reg unload "HKU\DefUser"
```

Shutdown Event Tracker off, verbose status on, page file not wiped at shutdown:

```powershell
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" /v ShutdownReasonOn /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" /v ShutdownReasonUI /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v VerboseStatus /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ClearPageFileAtShutdown /t REG_DWORD /d 0 /f
```

Boot menu timeout, hibernate off, High Performance power plan:

```powershell
bcdedit /timeout 3
powercfg /hibernate off
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /getactivescheme
```

Server Manager must not open at every logon:

```powershell
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" /v DoNotOpenAtLogon /t REG_DWORD /d 1 /f
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName ServerManager | Disable-ScheduledTask
```

## Step 2: network (safe items only)

Nothing here changes IP, gateway, DNS, bindings, offloads, MTU, IPv6 or firewall. Nothing restarts a NIC.

NIC power saving off on connected NICs. `-NoRestart` means the setting is applied at the next reboot, so there is no link drop while you are on the IPLC:

```powershell
Get-NetAdapterPowerManagement | Format-Table Name, AllowComputerToTurnOffDevice, DeviceSleepOnDisconnect, SelectiveSuspend -AutoSize
Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object { Set-NetAdapterPowerManagement -Name $_.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction SilentlyContinue }
```

(`Unsupported` in the first table is normal for server NICs; then there is nothing to change.)

RDP keep-alives, so sessions dropped by the WAN are detected and firewall/NAT state stays alive:

```powershell
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v KeepAliveEnable   /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v KeepAliveInterval /t REG_DWORD /d 1 /f
ipconfig /flushdns
```

When IPLC-1 is patched to the second NIC later: give it an IP but **no second default gateway**. Two default gateways cause asymmetric routing and RDP drops. Add specific routes for the IPLC-1 networks instead, for example `route -p add 10.1.0.0 mask 255.255.0.0 <iplc1-gateway>`.

## Step 3: cleanup

Check nothing is pending first (both must say "not found"):

```powershell
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
```

Component store (5-20 minutes, do not interrupt; no `/ResetBase`, so updates stay uninstallable):

```powershell
Dism /Online /Cleanup-Image /AnalyzeComponentStore
Dism /Online /Cleanup-Image /StartComponentCleanup
```

Windows Update download cache (only `Download`, update history is kept) and Delivery Optimization cache:

```powershell
Stop-Service wuauserv, bits -Force
Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service bits, wuauserv
Delete-DeliveryOptimizationCache -Force
```

Disk Cleanup, silent, with a conservative handler set (Device Driver Packages, Recycle Bin, Defender, ESD files are deliberately excluded):

```powershell
$h = 'Active Setup Temp Folders','D3D Shader Cache','Delivery Optimization Files','Downloaded Program Files','Internet Cache Files','Old ChkDsk Files','Previous Installations','Setup Log Files','System error memory dump files','System error minidump files','Temporary Files','Temporary Setup Files','Thumbnail Cache','Update Cleanup','Upgrade Discarded Files','Windows Error Reporting Files','Windows Upgrade Log Files'
$vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
Get-ChildItem $vc | ForEach-Object { if ($h -contains $_.PSChildName) { Set-ItemProperty $_.PSPath StateFlags0064 2 -Type DWord } else { Remove-ItemProperty $_.PSPath StateFlags0064 -ErrorAction SilentlyContinue } }
Start-Process cleanmgr.exe -ArgumentList '/sagerun:64' -Wait
```

Temp folders (files in use are simply skipped):

```powershell
Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\*"            -Recurse -Force -ErrorAction SilentlyContinue
```

Setup leftovers and archived logs:

```powershell
Remove-Item "$env:SystemRoot\Logs\CBS\CbsPersist_*" -Force -ErrorAction SilentlyContinue
Get-ChildItem "$env:SystemRoot\Logs\WindowsUpdate\*.etl" | Where-Object LastWriteTime -lt (Get-Date).AddDays(-7) | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Logs\MoSetup\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Panther\*.log", "$env:SystemRoot\Panther\unattend*.xml", "$env:SystemRoot\Panther\UnattendGC\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\System32\Sysprep\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\WER\ReportQueue\*", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force -ErrorAction SilentlyContinue
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
```

## Reboot and measure

```powershell
shutdown /r /f /t 0
```

The **first** reboot after step 3 can be slower: Windows shows "Cleaning up... do not turn off" while the component cleanup finishes. Measure the **second** reboot with the `Get-WinEvent` command from step 0, or run the script with `-ReportOnly`.

On a dedicated server most of the remaining time is firmware, not Windows: in the BIOS/UEFI disable PXE/network boot ROMs you do not use, unused option ROMs, and enable Fast Boot if the vendor offers it.

## Deliberately NOT done (would risk the IPLC link or the OS)

- `netsh winsock reset`, `netsh int ip reset`: wipe static IP configuration.
- `Disable-NetAdapter`, `Restart-NetAdapter`, `Set-NetAdapterAdvancedProperty`, offload/RSS/LSO/EEE changes: reset the link.
- Disabling IPv6, NetBIOS, the firewall, or changing TCP autotuning / congestion provider: defaults on 2022/2025 are correct.
- `Dism /ResetBase`: makes installed updates uninstallable.
- Deleting `WinSxS`, `Windows\Installer`, `System Volume Information`, event logs, `Prefetch`, `SoftwareDistribution\DataStore`.
- Disabling services or scheduled tasks beyond Server Manager auto-start.
- Any automatic reboot: the script only reboots with `-RebootWhenDone`.

## Rollback

Every registry value the script changes is recorded with its previous value in
`C:\ProgramData\ServerTune\<timestamp>\registry-old-values.tsv`. The baseline exports in the same folder cover bcdedit, power plans, IP configuration, routes and NIC settings.

Quick manual rollback of the main items:

```powershell
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d 20000 /f
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 0 /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Reliability" /f
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v VerboseStatus /f
bcdedit /timeout 30
powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" /v DoNotOpenAtLogon /f
Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName ServerManager
```

## Script usage (all other servers)

```powershell
# preview only, changes nothing
powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -DryRun

# apply all three sections, no reboot
powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1

# apply and reboot at the end (10 s delay, forced)
powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -RebootWhenDone

# after the reboot: show measured reboot time and NIC summary, no changes
powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -ReportOnly

# only cleanup (for example after installing updates and rebooting)
powershell -ExecutionPolicy Bypass -File .\Optimize-RdpServer.ps1 -SkipRebootTweaks -SkipNetwork
```

Log, baseline and rollback data: `C:\ProgramData\ServerTune\<timestamp>\`.
