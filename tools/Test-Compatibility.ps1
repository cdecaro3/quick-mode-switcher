# Test-Compatibility.ps1
# Read-only. Checks whether this laptop's BIOS supports the mode command Quick Mode Switcher uses,
# and lists the HP software running. It changes nothing.
# Run in an Administrator PowerShell from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\tools\Test-Compatibility.ps1

$names = @('Performance', 'Balanced', 'Cool', 'Quiet', 'Power Saver')

$log = New-Object System.Collections.Generic.List[string]
function Log([string]$s) { $log.Add($s); Write-Host $s }
function Hex($b) { (@($b) | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' ' }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an Administrator PowerShell.' -ForegroundColor Red
    exit 1
}

# --- Laptop ---
$cs   = Get-CimInstance Win32_ComputerSystem
$bb   = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
Log "Model: $($cs.Manufacturer) $($cs.Model)"
Log "Board: $($bb.Product)   BIOS: $($bios.SMBIOSBIOSVersion)"

# --- BIOS mode command ---
$verdict = $null
$cls   = Get-CimClass    -Namespace root/wmi -ClassName hpqBIntM   -ErrorAction SilentlyContinue
$inCls = Get-CimClass    -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue
$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM   -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $cls -or -not $inCls -or -not $inst) {
    Log "HP BIOS interface (root\wmi hpqBIntM): not found"
    $verdict = 'Not compatible: this laptop does not have HP''s BIOS interface.'
} else {
    Log "HP BIOS interface (root\wmi hpqBIntM): found"
    try {
        $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
            Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
            Command     = [uint32]1                          # 1 = read
            CommandType = [uint32]0x4C                       # thermal profile
            Size        = [uint32]4
            hpqBData    = [byte[]](0, 0, 0, 0)
        }
        $o = (Invoke-CimMethod -InputObject $inst -MethodName hpqBIOSInt128 -Arguments @{ InData = $din } -ErrorAction Stop).OutData
        $sign = [System.Text.Encoding]::ASCII.GetString([byte[]]@($o.Sign))
        $b = [byte[]](@($o.Data)[0..3])
        Log "Mode read (0x4C): return code $($o.rwReturnCode), signature $sign, data [$(Hex $b)]"
        if ($o.rwReturnCode -eq 0 -and $sign -eq 'PASS' -and $b[0] -le 4) {
            $verdict = "Likely compatible: the BIOS answered the mode command and reports $($names[$b[0]]). Run Get-ModeValues.ps1 to confirm the values match."
        } elseif ($o.rwReturnCode -eq 0) {
            $verdict = "Unclear: the BIOS answered, but with a mode value ($('{0:X2}' -f $b[0])) Quick Mode Switcher doesn't know."
        } else {
            $verdict = "Not compatible: the BIOS doesn't support the mode command (return code $($o.rwReturnCode))."
        }
    } catch {
        Log "Mode read (0x4C): error: $($_.Exception.Message)"
        $verdict = 'Not compatible: the mode command failed.'
    }
}
if ($cs.Model -match 'OMEN|Victus') {
    $verdict = 'Not supported: Omen and Victus laptops use different mode values.'
}

# --- HP software running ---
Log ''
Log 'HP software running (memory in use):'
$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'HP*' -or $_.ProcessName -like 'myHP*' -or $_.Company -like 'HP*' }
foreach ($p in ($procs | Sort-Object WorkingSet64 -Descending)) { Log ('  {0,-36} {1,5:N0} MB' -f $p.ProcessName, ($p.WorkingSet64 / 1MB)) }
if (-not $procs) { Log '  none' }

Log ''
Log "RESULT: $verdict"

try { Set-Clipboard -Value ($log -join "`r`n"); Write-Host "`nResults copied to the clipboard." -ForegroundColor Green } catch {}
