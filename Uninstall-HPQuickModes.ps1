# Uninstall-HPQuickModes.ps1
# Removes HP Quick Modes: stops it, deletes its scheduled task and its entry in Windows' Installed apps,
# and deletes C:\Program Files\HPQuickModes (including its settings). It doesn't change the current mode.
# Run it from Settings > Apps > Installed apps > HP Quick Modes > Uninstall, or:
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-HPQuickModes.ps1

Add-Type -AssemblyName System.Windows.Forms

# Needs admin rights; ask for them if it was started without
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('Uninstalling HP Quick Modes needs administrator rights.', 'HP Quick Modes', 'OK', 'Warning')
    }
    exit
}

$taskName = 'HP Quick Modes'
$dir      = Join-Path $env:ProgramFiles 'HPQuickModes'
$appsKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HPQuickModes'

# Stop it
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*HPQuickModes.ps1*' -and
                   $_.CommandLine -notlike '*Install-HPQuickModes*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Remove the task, the Installed apps entry, and the files
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path $appsKey -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue

$msg = if (Test-Path $dir) {
    "HP Quick Modes was removed, except for its folder ($dir), which couldn't be deleted. You can delete it yourself."
} else {
    'HP Quick Modes was removed.'
}
Write-Host $msg
[void][System.Windows.Forms.MessageBox]::Show($msg, 'HP Quick Modes', 'OK', 'Information')
