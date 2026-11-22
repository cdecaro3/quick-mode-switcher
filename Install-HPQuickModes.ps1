# Install-HPQuickModes.ps1
# Installs HPQuickModes.ps1 so it starts at sign-in with admin rights and no prompt, and adds an
# entry to Windows' Installed apps so it can be uninstalled from Settings.
# Run in an Administrator PowerShell, from the folder with HPQuickModes.ps1 and Uninstall-HPQuickModes.ps1:
#   powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1
# To remove everything it set up, uninstall from Settings > Apps > Installed apps, or run
# Uninstall-HPQuickModes.ps1 (-Uninstall here does the same).

param([switch]$Uninstall)

$taskName = 'HP Quick Modes'
# Program Files is admin-only, so nothing without admin rights can change the script that runs as admin
$dir     = Join-Path $env:ProgramFiles 'HPQuickModes'
$target  = Join-Path $dir 'HPQuickModes.ps1'
$appsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HPQuickModes'

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
    & (Join-Path $PSScriptRoot 'Uninstall-HPQuickModes.ps1')
    exit
}

$src       = Join-Path $PSScriptRoot 'HPQuickModes.ps1'
$uninstSrc = Join-Path $PSScriptRoot 'Uninstall-HPQuickModes.ps1'
if (-not (Test-Path $src) -or -not (Test-Path $uninstSrc)) {
    Write-Host "HPQuickModes.ps1 and Uninstall-HPQuickModes.ps1 need to be in the same folder as this installer ($PSScriptRoot)." -ForegroundColor Red
    exit 1
}

# Does this laptop answer the mode command the way HP Quick Modes expects? (read-only)
function Test-Bios {
    try {
        $inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction Stop | Select-Object -First 1
        $inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction Stop
        $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
            Sign = [byte[]](0x53, 0x45, 0x43, 0x55); Command = [uint32]1; CommandType = [uint32]0x4C
            Size = [uint32]4; hpqBData = [byte[]](0, 0, 0, 0)
        }
        $o = (Invoke-CimMethod -InputObject $inst -MethodName hpqBIOSInt128 -Arguments @{ InData = $din } -ErrorAction Stop).OutData
        $sign = [System.Text.Encoding]::ASCII.GetString([byte[]]@($o.Sign))
        return ($o.rwReturnCode -eq 0 -and $sign -eq 'PASS' -and @($o.Data)[0] -le 4)
    } catch {
        return $false
    }
}
if (-not (Test-Bios)) {
    Write-Host "This laptop doesn't seem to support HP Quick Modes. tools\Test-Compatibility.ps1 shows details." -ForegroundColor Yellow
    if ((Read-Host 'Install anyway? (y/n)') -ne 'y') { exit 1 }
}

Stop-Tray
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item -Path $src -Destination $target -Force
Copy-Item -Path $uninstSrc -Destination $dir -Force
Get-ChildItem -Path $dir -Filter '*.ps1' | Unblock-File

# Entry in Settings > Apps > Installed apps, so it can be uninstalled like any other app
New-Item -Path $appsKey -Force | Out-Null
Set-ItemProperty -Path $appsKey -Name DisplayName     -Value 'HP Quick Modes'
Set-ItemProperty -Path $appsKey -Name Publisher       -Value 'HP Quick Modes (unofficial, not made by HP)'
Set-ItemProperty -Path $appsKey -Name InstallLocation -Value $dir
Set-ItemProperty -Path $appsKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'Uninstall-HPQuickModes.ps1')`""
Set-ItemProperty -Path $appsKey -Name NoModify        -Value 1 -Type DWord
Set-ItemProperty -Path $appsKey -Name NoRepair        -Value 1 -Type DWord

# The task starts the app for whoever is signed in, which may not be the account running this installer
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { $user = $id.Name }
if ($user -ne $id.Name) {
    Write-Host "Note: you're running this as $($id.Name), but $user is signed in. HP Quick Modes will start when $user signs in, and that account needs to be an administrator for it to work." -ForegroundColor Yellow
}
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

# Check that it actually started
$started = $false
for ($i = 0; $i -lt 10 -and -not $started; $i++) {
    Start-Sleep -Seconds 1
    $started = [bool](Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$target*" })
}
if ($started) {
    Write-Host "Installed to $dir and running. It will start automatically when you sign in." -ForegroundColor Green
    Write-Host 'If you don''t see the icon, check the ^ overflow area of the taskbar.'
} else {
    Write-Host "Installed to $dir, but it doesn't seem to have started." -ForegroundColor Yellow
    Write-Host 'Run HPQuickModes.ps1 directly from this folder to see any error, or check the "HP Quick Modes" task in Task Scheduler.'
}
