# HPQuickModes.ps1
# System-tray menu for switching the HP Spectre x360 14-eu000's modes (fans, power limits).
# Sends only two BIOS commands: read the mode, and set a mode (00-04), the same ones tested with
# hp-mode-write-test.ps1. Needs admin rights; Install-HPQuickModes.ps1 makes it start at login
# without a prompt.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace HPQuickModes -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr hIcon);'
[System.Windows.Forms.Application]::EnableVisualStyles()

# Only one copy at a time
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\HPQuickModes', [ref]$created)
if (-not $created) { exit }

# Index = BIOS value
$modeNames = @('Performance', 'Balanced', 'Cool', 'Quiet', 'Power Saver')
$letters   = @('P', 'B', 'C', 'Q', 'S')
$colors    = @('#E8590C', '#1C7ED6', '#1098AD', '#37B24D', '#868E96')

# ---------- Settings (last mode, re-apply at login) ----------
$settingsPath = Join-Path $PSScriptRoot 'settings.json'

function Get-Settings {
    $s = @{ lastMode = -1; restoreAtLogin = $true }
    try {
        if (Test-Path $settingsPath) {
            $j = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($j.lastMode -ge 0 -and $j.lastMode -le 4) { $s.lastMode = [int]$j.lastMode }
            if ($null -ne $j.restoreAtLogin) { $s.restoreAtLogin = [bool]$j.restoreAtLogin }
        }
    } catch {}
    return $s
}

function Save-Settings {
    try { $script:settings | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding ASCII } catch {}
}

$script:settings = Get-Settings

# ---------- BIOS ----------
$script:inst  = Get-CimInstance -Namespace root/wmi -ClassName hpqBIntM -ErrorAction SilentlyContinue | Select-Object -First 1
$script:inCls = Get-CimClass   -Namespace root/wmi -ClassName hpqBDataIn -ErrorAction SilentlyContinue

function Invoke-Bios([uint32]$command, [byte[]]$data, [string]$method) {
    $din = New-CimInstance -CimClass $script:inCls -ClientOnly -Property @{
        Sign        = [byte[]](0x53, 0x45, 0x43, 0x55)   # "SECU"
        Command     = $command                           # 1 = read, 2 = write
        CommandType = [uint32]0x4C                       # thermal profile
        Size        = [uint32]$data.Length
        hpqBData    = $data
    }
    (Invoke-CimMethod -InputObject $script:inst -MethodName $method -Arguments @{ InData = $din } -ErrorAction Stop).OutData
}

# Returns the mode (0-4), or -1 if the reply doesn't look like the one verified on this laptop
function Read-Mode {
    try {
        $o = Invoke-Bios 1 ([byte[]](0, 0, 0, 0)) 'hpqBIOSInt128'
        $sign = [System.Text.Encoding]::ASCII.GetString([byte[]]@($o.Sign))
        $b = @($o.Data)
        if ($o.rwReturnCode -eq 0 -and $sign -eq 'PASS' -and $b.Count -ge 1 -and $b[0] -le 4) { return [int]$b[0] }
    } catch {}
    return -1
}

# Returns the BIOS return code (0 = success), or -1 if the call itself failed
function Write-Mode([int]$mode) {
    try { [int](Invoke-Bios 2 ([byte[]]($mode, 0, 0, 0)) 'hpqBIOSInt0').rwReturnCode } catch { -1 }
}

# ---------- Icons: a colored circle with the mode's letter ----------
function New-ModeIcon([string]$letter, [string]$hex) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
    $g.FillEllipse($brush, 0, 0, 31, 31)
    $font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($letter, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $fmt)
    $g.Dispose(); $brush.Dispose(); $font.Dispose(); $fmt.Dispose()
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [void][HPQuickModes.Native]::DestroyIcon($h)
    $bmp.Dispose()
    return $icon
}

$script:icons    = @(for ($i = 0; $i -lt 5; $i++) { New-ModeIcon $letters[$i] $colors[$i] })
$script:warnIcon = New-ModeIcon '!' '#C92A2A'

# ---------- Tray and menu ----------
$script:tray  = New-Object System.Windows.Forms.NotifyIcon
$script:menu  = New-Object System.Windows.Forms.ContextMenuStrip
$script:items = @()
$script:current = -1
$script:warned  = $false

function Show-Warning([string]$text) {
    $script:tray.ShowBalloonTip(6000, 'HP Quick Modes', $text, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Update-State {
    $m = Read-Mode
    $script:current = $m
    $ok = $m -ge 0
    for ($i = 0; $i -lt 5; $i++) {
        $script:items[$i].Checked = ($i -eq $m)
        $script:items[$i].Enabled = $ok
    }
    if ($ok) {
        $script:tray.Icon = $script:icons[$m]
        $script:tray.Text = "HP Quick Modes: $($modeNames[$m])"
        $script:warned = $false
    } else {
        $script:tray.Icon = $script:warnIcon
        $script:tray.Text = 'HP Quick Modes: BIOS reply not recognized'
        if (-not $script:warned) {
            $script:warned = $true
            Show-Warning 'The BIOS reply did not look like the one tested on this laptop, so switching is off. Run hp-mode-sample.ps1 to see what changed.'
        }
    }
}

function Set-Mode([int]$mode, [switch]$NoWarning) {
    if ($script:current -lt 0) { return }   # never write when the last read looked wrong
    $rc = Write-Mode $mode
    Start-Sleep -Milliseconds 500
    Update-State
    if ($script:current -ne $mode) { Start-Sleep -Milliseconds 1500; Update-State }
    if ($rc -eq 0 -and $script:current -eq $mode) {
        $script:settings.lastMode = $mode
        Save-Settings
    } elseif (-not $NoWarning) {
        $now = if ($script:current -ge 0) { $modeNames[$script:current] } else { 'unknown' }
        Show-Warning "Couldn't switch to $($modeNames[$mode]) (code $rc). Current mode: $now."
    }
}

# My HP's background process (HP.SystemControl.Background.exe) re-applies My HP's last pick when the
# charger is plugged in or unplugged, several times over the first ~5 seconds. Switch back to the mode
# picked here once it's done. Without My HP installed, the mode doesn't change, so this never acts.
function Restore-ChosenMode([bool]$warnIfStuck) {
    Update-State
    $want = $script:settings.lastMode
    if ($want -ge 0 -and $script:current -ge 0 -and $script:current -ne $want) {
        Set-Mode $want -NoWarning:(-not $warnIfStuck)
    }
}

for ($i = 0; $i -lt 5; $i++) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($modeNames[$i])
    $it.Tag = $i
    $it.add_Click({ param($s, $e) Set-Mode ([int]$s.Tag) })
    [void]$script:menu.Items.Add($it)
    $script:items += $it
}
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem('Re-apply last mode at login')
$script:restoreItem.CheckOnClick = $true
$script:restoreItem.Checked = $script:settings.restoreAtLogin
$script:restoreItem.add_Click({ $script:settings.restoreAtLogin = $script:restoreItem.Checked; Save-Settings })
[void]$script:menu.Items.Add($script:restoreItem)

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$exitItem.add_Click({ $script:tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
[void]$script:menu.Items.Add($exitItem)

$script:menu.add_Opening({ Update-State })
$script:tray.ContextMenuStrip = $script:menu

# Open the menu on left-click too (by default it only opens on right-click)
$script:showMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance, NonPublic')
$script:tray.add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:showMenu.Invoke($script:tray, $null) }
})

# Watch for the charger being plugged in or unplugged (a cheap check, no BIOS call).
# Switching back right away just starts a back-and-forth with My HP, so wait until it's done (its last
# re-apply came about 5 seconds in), switch back once, and check again later in case it was slow.
$script:lastPower    = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
$script:lastChangeAt = $null
$script:checkIdx     = 0
$checkAfter = @(7, 12, 20)   # seconds after a power change

$script:powerTimer = New-Object System.Windows.Forms.Timer
$script:powerTimer.Interval = 500
$script:powerTimer.add_Tick({
    $p = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    if ($p -ne $script:lastPower) {
        $script:lastPower    = $p
        $script:lastChangeAt = Get-Date
        $script:checkIdx     = 0
    }
    if ($script:lastChangeAt -and $script:checkIdx -lt $checkAfter.Count -and
        ((Get-Date) - $script:lastChangeAt).TotalSeconds -ge $checkAfter[$script:checkIdx]) {
        $script:checkIdx++
        Restore-ChosenMode ($script:checkIdx -eq $checkAfter.Count)   # warn only if the last check fails
    }
})

# Refresh the icon every 30 seconds. If the mode changed away from a power change
# (for example in My HP), treat it as the new chosen mode.
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 30000
$script:timer.add_Tick({
    Update-State
    $recent = $script:lastChangeAt -and ((Get-Date) - $script:lastChangeAt).TotalSeconds -lt 30
    if (-not $recent -and $script:current -ge 0 -and $script:current -ne $script:settings.lastMode) {
        $script:settings.lastMode = $script:current
        Save-Settings
    }
})

# ---------- Start ----------
# Right after login the BIOS interface can take a moment, so retry the first read briefly
for ($try = 0; $try -lt 5 -and (Read-Mode) -lt 0; $try++) { Start-Sleep -Seconds 2 }

$script:tray.Icon = $script:warnIcon
$script:tray.Visible = $true
Update-State

if ($script:current -ge 0 -and $script:settings.restoreAtLogin -and
    $script:settings.lastMode -ge 0 -and $script:settings.lastMode -ne $script:current) {
    Set-Mode $script:settings.lastMode
}

$script:timer.Start()
$script:powerTimer.Start()
[System.Windows.Forms.Application]::Run()

$script:powerTimer.Stop()
$script:timer.Stop()
$script:tray.Dispose()
$script:mutex.ReleaseMutex()
