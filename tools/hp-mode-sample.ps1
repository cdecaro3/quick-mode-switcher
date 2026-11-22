# hp-mode-sample.ps1
# Read-only, like hp-mode-check.ps1. It changes nothing.
# Each time you change the mode in My HP, type that mode's name here and press Enter;
# the script records what the BIOS and Windows report. Press Enter on an empty line to finish.
# Run in an Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\hp-mode-sample.ps1"

Add-Type -AssemblyName System.Windows.Forms

function Hex($bytes, [int]$n = 16) {
    if ($null -eq $bytes) { return '(none)' }
    (@($bytes) | Select-Object -First $n | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join ' '
}

$inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM | Select-Object -First 1
$inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn

function Read-Profile {
    try {
        $din = New-CimInstance -CimClass $inCls -ClientOnly -Property @{
            Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
            Command     = [uint32]1                          # 1 = read
            CommandType = [uint32]0x4C                       # thermal profile
            Size        = [uint32]4
            hpqBData    = [byte[]](0, 0, 0, 0)
        }
        $o = (Invoke-CimMethod -InputObject $inst -MethodName hpqBIOSInt128 -Arguments @{ InData = $din } -ErrorAction Stop).OutData
        "rc=$($o.rwReturnCode) data=[$(Hex $o.Data)]"
    } catch {
        "read ERROR: $($_.Exception.Message)"
    }
}

function Read-Windows {
    $pk   = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue
    $plan = (powercfg /getactivescheme) -join ' '
    if ($plan -match '\((.+)\)') { $plan = $matches[1] }
    $line = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    "plan=$plan  overlayAC=$($pk.ActiveOverlayAcPowerScheme)  overlayDC=$($pk.ActiveOverlayDcPowerScheme)  power=$line"
}

$log = New-Object System.Collections.Generic.List[string]
$start = "start: $(Read-Profile)  $(Read-Windows)"
$log.Add($start); Write-Host $start

while ($true) {
    $label = Read-Host "`nSwitch the mode in My HP, wait ~5 seconds, then type the mode's name (Enter on an empty line to finish)"
    if ([string]::IsNullOrWhiteSpace($label)) { break }
    $line = "${label}: $(Read-Profile)  $(Read-Windows)"
    $log.Add($line); Write-Host $line
}

$text = $log -join "`r`n"
try {
    Set-Clipboard -Value $text
    Write-Host "`nCopied to clipboard. Paste it back to Claude." -ForegroundColor Green
} catch {
    Write-Host "`nCopy the lines above and paste them back to Claude."
}
