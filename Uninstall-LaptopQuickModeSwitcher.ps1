# Uninstall-LaptopQuickModeSwitcher.ps1
# Removes Laptop Quick Mode Switcher: stops it, deletes its scheduled task and its entry in Windows' Installed apps,
# and deletes C:\Program Files\LaptopQuickModeSwitcher (including its settings). It doesn't change the current mode.
# Run it from Settings > Apps > Installed apps > Laptop Quick Mode Switcher > Uninstall, or:
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-LaptopQuickModeSwitcher.ps1

Add-Type -AssemblyName System.Windows.Forms

$taskName = 'Laptop Quick Mode Switcher'
$dir      = Join-Path $env:ProgramFiles 'LaptopQuickModeSwitcher'
$appsKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LaptopQuickModeSwitcher'

# Run from a temporary copy when started from the install folder (as Settings does), so the folder
# can be deleted; and ask for admin rights if it was started without them.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$fromInstallDir = $PSScriptRoot -and ($PSScriptRoot.TrimEnd('\') -eq $dir.TrimEnd('\'))
if ($fromInstallDir -or -not $isAdmin) {
    $runFrom = $PSCommandPath
    if ($fromInstallDir) {
        $runFrom = Join-Path $env:TEMP 'Uninstall-LaptopQuickModeSwitcher.ps1'
        Copy-Item -Path $PSCommandPath -Destination $runFrom -Force
    }
    $launch = @{ FilePath = 'powershell.exe'; ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$runFrom`"" }
    if (-not $isAdmin) { $launch.Verb = 'RunAs' }
    try {
        Start-Process @launch
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('Uninstalling Laptop Quick Mode Switcher needs administrator rights.', 'Laptop Quick Mode Switcher', 'OK', 'Warning')
    }
    exit
}
Set-Location $env:TEMP   # don't hold the install folder open

function Get-AppTasks {
    # The task by name, plus any other task that runs Laptop Quick Mode Switcher (for example, from a version with a different task name)
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -eq $taskName -or (@($_.Actions | ForEach-Object { $_.Arguments }) -like '*LaptopQuickModeSwitcher.ps1*') }
}
function Get-AppProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*LaptopQuickModeSwitcher.ps1*' -and
                       $_.CommandLine -notlike '*Install-LaptopQuickModeSwitcher*' }   # also skips this uninstaller
}

# Stop it
Get-AppTasks | ForEach-Object { Stop-ScheduledTask -InputObject $_ -ErrorAction SilentlyContinue }
Get-AppProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Remove the tasks, the Installed apps entry, and the files
Get-AppTasks | ForEach-Object { Unregister-ScheduledTask -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue }
Remove-Item -Path $appsKey -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue

# Check that everything is gone
$left = @()
if (Get-AppTasks)       { $left += 'its scheduled task (remove "Laptop Quick Mode Switcher" in Task Scheduler)' }
if (Test-Path $appsKey) { $left += 'its entry in Installed apps' }
if (Test-Path $dir)     { $left += "its folder ($dir), which you can delete yourself" }
if (Get-AppProcesses)   { $left += 'the running app (restart to stop it)' }

$msg = if ($left) {
    "Laptop Quick Mode Switcher was removed, except for:`n- " + ($left -join "`n- ")
} else {
    'Laptop Quick Mode Switcher was completely removed. The laptop stays in its current mode.'
}
Write-Host $msg
[void][System.Windows.Forms.MessageBox]::Show($msg, 'Laptop Quick Mode Switcher', 'OK', $(if ($left) { 'Warning' } else { 'Information' }))

# Remove the temporary copy this ran from, if it was one
if ($PSCommandPath -like "$env:TEMP*") { Remove-Item -Path $PSCommandPath -Force -ErrorAction SilentlyContinue }
