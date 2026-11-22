# Get-ModeValues.ps1
# Read-only. Records the BIOS value for each mode you pick in My HP and checks it against the
# values Laptop Quick Mode Switcher uses. It changes nothing. Needs My HP installed.
# Run in an Administrator PowerShell from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\tools\Get-ModeValues.ps1
# Each time you pick a mode in My HP, wait about 5 seconds, type that mode's name here and press
# Enter. Press Enter on an empty line to finish.

$expected = @{ 'performance' = 0; 'balanced' = 1; 'cool' = 2; 'quiet' = 3; 'power saver' = 4 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an Administrator PowerShell.' -ForegroundColor Red
    exit 1
}

$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue | Select-Object -First 1
$inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue
if (-not $inst -or -not $inCls) { Write-Host 'HP BIOS interface not found; this laptop is not compatible.' -ForegroundColor Red; exit 1 }

function Hex($b) { (@($b) | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' ' }

function Read-Raw {
    try {
        $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
            Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
            Command     = [uint32]1                          # 1 = read
            CommandType = [uint32]0x4C                       # thermal profile
            Size        = [uint32]4
            hpqBData    = [byte[]](0, 0, 0, 0)
        }
        $o = (Invoke-CimMethod -InputObject $inst -MethodName hpqBIOSInt128 -Arguments @{ InData = $din } -ErrorAction Stop).OutData
        if ($o.rwReturnCode -eq 0) { return [byte[]](@($o.Data)[0..3]) }
    } catch {}
    return $null
}

$log = New-Object System.Collections.Generic.List[string]
function Log([string]$s) { $log.Add($s); Write-Host $s }

$matched = 0; $different = 0
$start = Read-Raw
Log "Current value: [$(Hex $start)]"

while ($true) {
    $label = Read-Host "`nPick a mode in My HP, wait about 5 seconds, then type its name (Enter on an empty line to finish)"
    if ([string]::IsNullOrWhiteSpace($label)) { break }
    $raw = Read-Raw
    if ($null -eq $raw) { Log "${label}: read failed"; continue }
    $key = $label.Trim().ToLower()
    if ($expected.ContainsKey($key)) {
        if ($raw[0] -eq $expected[$key]) { $matched++; Log "${label}: [$(Hex $raw)]  first byte matches ($('{0:X2}' -f $expected[$key]))" }
        else { $different++; Log "${label}: [$(Hex $raw)]  DIFFERENT: Laptop Quick Mode Switcher expects $('{0:X2}' -f $expected[$key])" }
    } else {
        Log "${label}: [$(Hex $raw)]  (not one of: Performance, Balanced, Cool, Quiet, Power Saver)"
    }
}

Log ''
if ($different -gt 0) { Log "RESULT: $different mode(s) use different values, so Laptop Quick Mode Switcher would set the wrong modes on this laptop." }
elseif ($matched -gt 0) { Log "RESULT: all $matched mode(s) checked match. Next, try Test-ModeSwitch.ps1." }
else { Log 'RESULT: no modes checked.' }

try { Set-Clipboard -Value ($log -join "`r`n"); Write-Host "`nResults copied to the clipboard." -ForegroundColor Green } catch {}
