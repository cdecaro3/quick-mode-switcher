# Watch-PlugUnplug.ps1
# Read-only. Shows what happens to the mode when the charger is plugged in or unplugged: whether
# My HP changes it, and how long Laptop Quick Mode Switcher takes to switch it back. It changes nothing.
# To see the switch-back: pick one mode in My HP (for example Balanced), then a different one in the
# Laptop Quick Mode Switcher tray menu (for example Quiet), and leave Laptop Quick Mode Switcher running.
# Run in an Administrator PowerShell from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\tools\Watch-PlugUnplug.ps1
# Then unplug and plug in 2-3 times, about 10 seconds apart. Press Enter to stop.

Add-Type -AssemblyName System.Windows.Forms
$names = @('Performance', 'Balanced', 'Cool', 'Quiet', 'Power Saver')

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an Administrator PowerShell.' -ForegroundColor Red
    exit 1
}

$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue | Select-Object -First 1
$inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue
if (-not $inst -or -not $inCls) { Write-Host 'HP BIOS interface not found; this laptop is not compatible.' -ForegroundColor Red; exit 1 }

function Read-Mode {
    try {
        $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
            Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
            Command     = [uint32]1                          # 1 = read
            CommandType = [uint32]0x4C                       # thermal profile
            Size        = [uint32]4
            hpqBData    = [byte[]](0, 0, 0, 0)
        }
        $o = (Invoke-CimMethod -InputObject $inst -MethodName hpqBIOSInt128 -Arguments @{ InData = $din } -ErrorAction Stop).OutData
        if ($o.rwReturnCode -eq 0) { return [int]@($o.Data)[0] }
    } catch {}
    return -1
}
function Show-Mode([int]$m) { if ($m -ge 0 -and $m -le 4) { $names[$m] } else { 'unknown' } }

$log = New-Object System.Collections.Generic.List[string]
function Log([string]$s) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss.f'), $s
    $log.Add($line); Write-Host $line
}

# Is Laptop Quick Mode Switcher running?
$tray = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*LaptopQuickModeSwitcher.ps1*' }
if ($tray) { Log 'Laptop Quick Mode Switcher is running.' }
else { Log 'WARNING: Laptop Quick Mode Switcher does not seem to be running, so nothing will switch the mode back.' }

$want = Read-Mode
if ($want -lt 0) { Log 'Could not read the BIOS mode.'; exit }
Log "Your mode: $(Show-Mode $want)"
Write-Host 'Unplug and plug in 2-3 times, about 10 seconds apart. Press Enter to stop.' -ForegroundColor Yellow

$power  = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
$mode   = $want
$events = New-Object System.Collections.Generic.List[object]
$evt    = $null

while ($true) {
    if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }

    $p = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    if ($p -ne $power) {
        $power = $p
        $evt = @{ at = Get-Date; label = $(if ($p -eq 'Online') { 'Plugged in' } else { 'Unplugged' });
                  to = $null; switchedAfter = $null; restoredAfter = $null }
        $events.Add($evt)
        Log "$($evt.label)"
    }

    $m = Read-Mode
    if ($m -ne $mode -and $m -ge 0) {
        $mode = $m
        $t = if ($evt) { '{0:N1} s after {1}' -f ((Get-Date) - $evt.at).TotalSeconds, $evt.label.ToLower() } else { 'no plug/unplug' }
        Log "  mode -> $(Show-Mode $m)  ($t)"
        if ($evt) {
            $secs = ((Get-Date) - $evt.at).TotalSeconds
            if ($m -ne $want -and $null -eq $evt.switchedAfter) { $evt.switchedAfter = $secs; $evt.to = $m }
            elseif ($m -eq $want -and $null -ne $evt.switchedAfter -and $null -eq $evt.restoredAfter) { $evt.restoredAfter = $secs }
        }
    }
    Start-Sleep -Milliseconds 100
}

Log '--- Summary ---'
if ($events.Count -eq 0) { Log 'No plug/unplugs seen.' }
foreach ($e in $events) {
    if ($null -eq $e.switchedAfter) {
        Log "$($e.label): the mode didn't change (My HP isn't installed, or its setting matches your mode)."
    } elseif ($null -eq $e.restoredAfter) {
        Log ("{0}: switched to {1} after {2:N1} s, and it was NOT switched back." -f $e.label, (Show-Mode $e.to), $e.switchedAfter)
    } else {
        Log ("{0}: switched to {1} after {2:N1} s; Laptop Quick Mode Switcher switched it back {3:N1} s later." -f $e.label, (Show-Mode $e.to), $e.switchedAfter, ($e.restoredAfter - $e.switchedAfter))
    }
}
$end = Read-Mode
Log "Mode now: $(Show-Mode $end) $(if ($end -eq $want) { '(your mode)' } else { "(expected $(Show-Mode $want))" })"

$text = $log -join "`r`n"
try {
    Set-Clipboard -Value $text
    Write-Host "`nResults copied to the clipboard." -ForegroundColor Green
} catch {}
