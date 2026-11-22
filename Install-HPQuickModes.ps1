# Install-HPQuickModes.ps1
# Installs HPQuickModes.ps1 so it starts at login with admin rights and no prompt.
# Run in an Administrator PowerShell, with HPQuickModes.ps1 in the same folder as this file:
#   powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1
# To remove everything it set up:
#   powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1 -Uninstall

param([switch]$Uninstall)

$taskName = 'HP Quick Modes'
# Program Files is admin-only, so nothing without admin rights can change the script that runs as admin
$dir    = Join-Path $env:ProgramFiles 'HPQuickModes'
$target = Join-Path $dir 'HPQuickModes.ps1'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an Administrator PowerShell.' -ForegroundColor Red
    exit 1
}

function Stop-Tray {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*HPQuickModes.ps1*' -and
                       $_.CommandLine -notlike '*Install-HPQuickModes*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-Tray
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed the scheduled task and the HPQuickModes folder.' -ForegroundColor Green
    exit 0
}

$src = Join-Path $PSScriptRoot 'HPQuickModes.ps1'
if (-not (Test-Path $src)) {
    Write-Host "HPQuickModes.ps1 needs to be in the same folder as this installer ($PSScriptRoot)." -ForegroundColor Red
    exit 1
}

Stop-Tray
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item -Path $src -Destination $target -Force
Unblock-File -Path $target

$user = $id.Name
# conhost --headless runs PowerShell with no console window at all
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
# Defaults would stop it on battery and after 3 days, so turn those off
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Tray menu for switching HP laptop modes' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "Installed to $dir and set to start at login." -ForegroundColor Green
Write-Host 'The icon should appear in a few seconds; check the ^ overflow area of the taskbar.'
