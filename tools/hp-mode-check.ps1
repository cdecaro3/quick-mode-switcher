# hp-mode-check.ps1
# Read-only diagnostic for HP thermal profiles. It changes nothing.
# Run in an Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\hp-mode-check.ps1"

$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$s) { $lines.Add($s); Write-Host $s }

function Hex($bytes, [int]$n = 8) {
    if ($null -eq $bytes) { return '(none)' }
    (@($bytes) | Select-Object -First $n | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' '
}

function Props($obj) {
    if ($null -eq $obj) { return '(no output)' }
    ($obj.CimInstanceProperties | ForEach-Object {
        if ($_.Value -is [array]) { "$($_.Name)=[$(Hex $_.Value)]" } else { "$($_.Name)=$($_.Value)" }
    }) -join '  '
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "== HP mode check =="
Log "Admin: $isAdmin   PowerShell: $($PSVersionTable.PSVersion)"
if (-not $isAdmin) { Log "NOTE: not running as Administrator; the BIOS calls below may fail." }

# --- System ---
$cs   = Get-CimInstance Win32_ComputerSystem
$bb   = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
Log "Model: $($cs.Manufacturer) $($cs.Model)   SKU: $($cs.SystemSKUNumber)"
Log "Board: $($bb.Product)   BIOS: $($bios.SMBIOSBIOSVersion) $($bios.ReleaseDate)"
Log "CPU: $($cpu.Name.Trim())"

# --- HP BIOS WMI interface ---
$pnp = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'ACPI\PNP0C14*' }
foreach ($p in $pnp) { Log "WMI device: $($p.InstanceId) [$($p.Status)]" }

$cls = Get-CimClass -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue
if (-not $cls) {
    Log "hpqBIntM: NOT FOUND"
} else {
    Log "hpqBIntM methods: $(($cls.CimClassMethods | ForEach-Object { $_.Name }) -join ', ')"
    $inCls = Get-CimClass -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue
    if ($inCls) { Log "hpqBDataIn fields: $(($inCls.CimClassProperties | ForEach-Object { $_.Name }) -join ', ')" }
    $inst = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $inst) { Log "hpqBIntM instance: NOT FOUND" }

    # Read (Command 1) of query 0x4C = thermal profile; the same call Linux's hp-wmi driver makes
    foreach ($m in 'hpqBIOSInt4', 'hpqBIOSInt128') {
        if (-not $inst -or -not $inCls) { break }
        try {
            $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
                Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
                Command     = [uint32]1                          # 1 = read
                CommandType = [uint32]0x4C                       # thermal profile
                Size        = [uint32]4
                hpqBData    = [byte[]](0, 0, 0, 0)
            }
            $r = Invoke-CimMethod -InputObject $inst -MethodName $m -Arguments @{ InData = $din } -ErrorAction Stop
            Log "$m read 0x4C -> $(Props $r.OutData)"
        } catch {
            Log "$m read 0x4C -> ERROR: $($_.Exception.Message)"
        }
    }

    # Fallback through the older WMI cmdlets (Windows PowerShell 5.1 only)
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            $w  = Get-WmiObject -Namespace root/wmi -Class hpqBIntM -ErrorAction Stop | Select-Object -First 1
            $di = ([wmiclass]'root/wmi:hpqBDataIn').CreateInstance()
            $di.Sign = [byte[]](0x53, 0x45, 0x43, 0x55); $di.Command = 1; $di.CommandType = 0x4C
            $di.Size = 4; $di.hpqBData = [byte[]](0, 0, 0, 0)
            $res = $w.hpqBIOSInt128($di)
            Log "WMI hpqBIOSInt128 read 0x4C -> rwReturnCode=$($res.OutData.rwReturnCode)  Data=[$(Hex $res.OutData.Data)]"
        } catch {
            Log "WMI fallback -> ERROR: $($_.Exception.Message)"
        }
    }
}

# --- Windows power settings ---
Log "Power plan: $((powercfg /getactivescheme) -join ' ')"
$pk = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue
if ($pk) { Log "Power mode overlay AC/DC: $($pk.ActiveOverlayAcPowerScheme) / $($pk.ActiveOverlayDcPowerScheme)" }

# --- HP software currently installed / running ---
Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AD2F1837.*' } |
    ForEach-Object { Log "App: $($_.Name) $($_.Version)" }
Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'HP*' -or $_.DisplayName -like 'HP *' } |
    ForEach-Object { Log "Service: $($_.Name) [$($_.Status)/$($_.StartType)] $($_.DisplayName)" }
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'HP*' -or $_.ProcessName -like 'myHP*' -or $_.Company -like 'HP*' } |
    ForEach-Object { Log ("Process: {0}  {1:N0} MB" -f $_.ProcessName, ($_.WorkingSet64 / 1MB)) }

$text = $lines -join "`r`n"
try {
    Set-Clipboard -Value $text
    Write-Host "`nCopied to clipboard. Paste it back to Claude." -ForegroundColor Green
} catch {
    Write-Host "`nCopy the text above and paste it back to Claude."
}
