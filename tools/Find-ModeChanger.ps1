# Find-ModeChanger.ps1
# Finds which HP background program changes the mode when the charger is plugged in or unplugged.
# On the Spectre x360 14 this is My HP's HP.SystemControl.Background.exe; use this on other models.
#   Part 1 (read-only): lists HP's running programs and services, and which app each belongs to.
#   Part 2: stops one app's programs at a time (until the next restart), sets a mode, and watches
#           plug/unplug. It stops at the first app whose programs make the mode stick.
# Before running: restart (so all HP software is running), pick a mode in My HP, and exit HP Quick
# Modes (it would switch the mode back itself).
# Run in an Administrator PowerShell from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\tools\Find-ModeChanger.ps1

Add-Type -AssemblyName System.Windows.Forms
$names = @('Performance', 'Balanced', 'Cool', 'Quiet', 'Power Saver')

$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue | Select-Object -First 1
$inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue
if (-not $inst -or -not $inCls) { Write-Host 'HP BIOS interface not found; this laptop is not compatible.' -ForegroundColor Red; exit 1 }

$log = New-Object System.Collections.Generic.List[string]
function Log([string]$s) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss.f'), $s
    $log.Add($line); Write-Host $line
}

function Invoke-Bios([uint32]$command, [byte[]]$data, [string]$method) {
    $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
        Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
        Command     = $command                           # 1 = read, 2 = write
        CommandType = [uint32]0x4C                       # thermal profile
        Size        = [uint32]$data.Length
        hpqBData    = $data
    }
    (Invoke-CimMethod -InputObject $inst -MethodName $method -Arguments @{ InData = $din } -ErrorAction Stop).OutData
}
function Read-Mode {
    try {
        $o = Invoke-Bios 1 ([byte[]](0, 0, 0, 0)) 'hpqBIOSInt128'
        if ($o.rwReturnCode -eq 0) { return [int]@($o.Data)[0] }
    } catch {}
    return -1
}
function Show-Mode([int]$m) { if ($m -ge 0 -and $m -le 4) { $names[$m] } else { 'unknown' } }
function Write-Mode([int]$m) { try { [int](Invoke-Bios 2 ([byte[]]($m, 0, 0, 0)) 'hpqBIOSInt0').rwReturnCode } catch { -1 } }

# HP programs: names starting with HP or myHP, plus HP's support helpers that don't
$hpProcNames = @('AppHelperCap', 'DiagsCap', 'NetworkCap', 'SysInfoCap', 'BridgeCommunication',
                 'DisplayControlService', 'TouchpointAnalyticsClientService')
function Test-HpName([string]$n) { $n -like 'HP*' -or $n -like 'myHP*' -or ($n -replace '\.exe$', '') -in $hpProcNames }

# Which app or install a program belongs to, from its command line
function Get-Origin([string]$cmd) {
    if ($cmd -match 'WindowsApps\\([^\\_]+)')     { return "app $($matches[1])" }
    if ($cmd -match 'FileRepository\\([^\\._]+)') { return "driver $($matches[1])" }
    if ($cmd -match '\\([^\\]+)\\[^\\]+\.exe')    { return "folder $($matches[1])" }
    return 'unknown'
}

# Is HP Quick Modes running? It would switch the mode back and spoil the test.
$tray = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*HPQuickModes.ps1*' }
if ($tray) {
    Write-Host 'HP Quick Modes is running. Exit it from its tray menu first, then run this again.' -ForegroundColor Red
    exit 1
}

# --- Part 1: what's running and where it comes from (read-only) ---
$svcByPid = @{}
Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId } |
    ForEach-Object { $svcByPid[[int]$_.ProcessId] = $_.Name }

$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { Test-HpName $_.Name } |
    ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Name -replace '\.exe$', ''
            Id      = [int]$_.ProcessId
            Origin  = Get-Origin ([string]$_.CommandLine)
            Service = $svcByPid[[int]$_.ProcessId]
        }
    })

Log '--- HP programs running, by app ---'
$groups = @($procs | Group-Object Origin | Sort-Object @{ Expression = { if ($_.Name -like '*myHP*') { 0 } else { 1 } } }, Name)
foreach ($g in $groups) {
    $list = ($g.Group | ForEach-Object { if ($_.Service) { "$($_.Name) (service $($_.Service))" } else { $_.Name } }) -join ', '
    Log "$($g.Name): $list"
}

Log '--- HP services ---'
Get-Service -ErrorAction SilentlyContinue |
    Where-Object { ($_.Name -like 'HP*' -or $_.DisplayName -like 'HP *') -and $_.Name -ne 'hpatchmon' } |
    Sort-Object Name | ForEach-Object { Log ('{0}  [{1}/{2}]' -f $_.Name, $_.Status, $_.StartType) }

# --- Part 2: stop one app's programs at a time and watch plug/unplug ---
function Get-WatchedProcs {
    $h = @{}
    Get-Process -ErrorAction SilentlyContinue | Where-Object { (Test-HpName $_.ProcessName) -or $_.ProcessName -eq 'backgroundTaskHost' } |
        ForEach-Object { $h[$_.Id] = $_.ProcessName }
    return $h
}

function Watch-Transitions([string]$label) {
    Write-Host "`nUnplug, wait about 10 seconds, plug back in, wait about 10 seconds. Do that twice, then press Enter." -ForegroundColor Yellow
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    $mode  = Read-Mode
    $seen  = Get-WatchedProcs
    $changes = 0; $flips = 0
    while ($true) {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }
        $p = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        if ($p -ne $power) { $power = $p; $changes++; Log "  power -> $p" }
        $m = Read-Mode
        if ($m -ne $mode) { $mode = $m; $flips++; Log "  mode  -> $(Show-Mode $m)" }
        $now = Get-WatchedProcs
        foreach ($id in @($now.Keys)) {
            if (-not $seen.ContainsKey($id)) {
                $c = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue).CommandLine
                Log "  started $($now[$id]) ($(Get-Origin $c))"
            }
        }
        $seen = $now
        Start-Sleep -Milliseconds 300
    }
    return @{ changes = $changes; flips = $flips }
}

$found = $null
foreach ($g in $groups) {
    $progs = ($g.Group.Name | Sort-Object -Unique) -join ', '
    $a = Read-Host "`nStop $($g.Name) ($progs) until the next restart, set a mode, and watch plug/unplug? Press Enter to run it, or type n to stop here"
    if ($a -eq 'n') { break }

    foreach ($p in $g.Group) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
    }
    Log "Stopped $($g.Name): $progs"
    Start-Sleep -Seconds 2

    $cur = Read-Mode
    if ($cur -lt 0) { Log 'Could not read the BIOS mode.'; break }
    $target = if ($cur -ne 3) { 3 } else { 1 }
    $rc = Write-Mode $target
    Start-Sleep -Seconds 1
    Log "Set $(Show-Mode $target) (return code $rc); now $(Show-Mode (Read-Mode))"

    $r = Watch-Transitions $g.Name
    if ($r.changes -lt 2) {
        Log "Inconclusive: fewer than 2 plug/unplugs."
    } elseif ($r.flips -eq 0) {
        $found = $g
        break
    } else {
        Log "The mode still changed, so it isn't (only) $($g.Name)."
    }
}

Log ''
if ($found) {
    Log "RESULT: the mode stopped changing once $($found.Name) was stopped ($(($found.Group.Name | Sort-Object -Unique) -join ', ')). That's what switches it on plug/unplug."
} else {
    Log 'RESULT: no single app found. If nothing changed the mode in the first place, My HP''s pick may already match the mode this script set.'
}
Log 'Stopped programs come back when you restart.'

try { Set-Clipboard -Value ($log -join "`r`n"); Write-Host "`nResults copied to the clipboard." -ForegroundColor Green } catch {}
