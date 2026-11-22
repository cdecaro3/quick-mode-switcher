# hp-mode-write-test.ps1
# Tests whether the BIOS accepts the "set mode" command. Asks before every change.
# Sends only the mode values My HP itself uses (00-04) and ends on the mode you started in.
# Run in an Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\hp-mode-write-test.ps1"

$names = @{ 0 = 'Performance'; 1 = 'Balanced'; 2 = 'Cool'; 3 = 'Quiet'; 4 = 'Power Saver' }

$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM | Select-Object -First 1
$inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn

$log = New-Object System.Collections.Generic.List[string]
function Log([string]$s) { $log.Add($s); Write-Host $s }
function Hex($b) { (@($b) | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' ' }
function Get-ModeName($v) { if ($names.ContainsKey([int]$v)) { $names[[int]$v] } else { "unknown ($v)" } }

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
    $o = Invoke-Bios 1 ([byte[]](0, 0, 0, 0)) 'hpqBIOSInt128'
    if ($o.rwReturnCode -ne 0) { throw "read failed, rwReturnCode=$($o.rwReturnCode)" }
    [byte[]](@($o.Data)[0..3])
}

function Write-Mode([byte[]]$bytes) {
    try {
        $o = Invoke-Bios 2 $bytes 'hpqBIOSInt0'
        [int]$o.rwReturnCode
    } catch {
        Log "  (call error: $($_.Exception.Message))"
        -1
    }
}

function Ask-Ok([string]$what) {
    $a = Read-Host "`n$what`nPress Enter to send it, or type n to stop"
    return ($a -ne 'n')
}

function Finish {
    $text = $log -join "`r`n"
    try {
        Set-Clipboard -Value $text
        Write-Host "`nCopied to clipboard. Paste it back to Claude." -ForegroundColor Green
    } catch {
        Write-Host "`nCopy the lines above and paste them back to Claude."
    }
    exit
}

# --- Starting point ---
$orig = Read-Mode
Log "Starting mode: $(Get-ModeName $orig[0])  raw=[$(Hex $orig)]"

# Builds the 4 bytes for a mode in whichever format step 1 found the BIOS accepts.
# The second byte can change on its own, so 'as read' re-reads it right before writing.
function Get-ModeBytes([byte]$mode) {
    if ($script:fmt -eq 'as read') { $cur = Read-Mode; [byte[]]($mode, $cur[1], $cur[2], $cur[3]) }
    else                          { [byte[]]($mode, 0, 0, 0) }
}

# --- Step 1: re-send the current mode, so nothing actually changes ---
if (-not (Ask-Ok "Step 1 of 3: re-send the current mode ($(Get-ModeName $orig[0])). Nothing should change.")) {
    Log 'Stopped before step 1.'; Finish
}
$script:fmt = $null
# 'mode only' is the format the Linux driver sends on HP laptops, so try it first
$formats = @(
    @{ label = 'mode only'; bytes = [byte[]]($orig[0], 0, 0, 0) },
    @{ label = 'as read';   bytes = [byte[]]($orig[0], $orig[1], $orig[2], $orig[3]) }
)
foreach ($f in $formats) {
    $rc = Write-Mode $f.bytes
    Log "Step 1, format '$($f.label)' [$(Hex $f.bytes)] -> rwReturnCode=$rc"
    if ($rc -eq 0) { $script:fmt = $f.label; break }
}
if (-not $script:fmt) { Log 'The BIOS refused both formats. Nothing was changed.'; Finish }
$now = Read-Mode
Log "After step 1: reads $(Get-ModeName $now[0]) [$(Hex $now)]"

# --- Step 2: switch to a different mode ---
$target = if ($orig[0] -eq 1) { [byte]2 } else { [byte]1 }
if (-not (Ask-Ok "Step 2 of 3: switch to $(Get-ModeName $target).")) {
    Log 'Stopped before step 2.'; Finish
}
$rc = Write-Mode (Get-ModeBytes $target)
Start-Sleep -Seconds 3
$now = Read-Mode
Log "Step 2, set $(Get-ModeName $target) -> rwReturnCode=$rc, now reads $(Get-ModeName $now[0]) [$(Hex $now)]"
$seen = Read-Host "Close and reopen My HP. Does it show $(Get-ModeName $target)? (y/n)"
Log "Step 2, My HP shows $(Get-ModeName $target): $seen"

# --- Step 3: switch back to where you started ---
if (Ask-Ok "Step 3 of 3: switch back to $(Get-ModeName $orig[0]).") {
    $rc = Write-Mode (Get-ModeBytes $orig[0])
    Start-Sleep -Seconds 3
    $now = Read-Mode
    Log "Step 3, set $(Get-ModeName $orig[0]) -> rwReturnCode=$rc, now reads $(Get-ModeName $now[0]) [$(Hex $now)]"
} else {
    Log "Skipped step 3; the laptop is still in $(Get-ModeName $target). Switch back in My HP if you like."
}
Finish
