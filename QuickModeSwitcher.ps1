# QuickModeSwitcher.ps1
# System-tray menu for switching the HP Spectre x360 14-eu0000's modes (fans, power limits).
# Sends only two BIOS commands: read the mode, and set a mode (00-04), the same ones tested with
# tools\Test-ModeSwitch.ps1. Needs admin rights; Install-QuickModeSwitcher.ps1 makes it start at login
# without a prompt.

$AppVersion = '0.1.0'   # shown in Windows' Installed apps; bump it with each release

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace QuickModeSwitcher -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr hIcon);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
# Draw at the screen's real scale, so the icon and menu are sharp instead of stretched
[void][QuickModeSwitcher.Native]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
# If something unexpected fails inside the menu or a timer, keep running instead of showing a crash dialog
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) })

function Show-Error([string]$text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, 'Quick Mode Switcher', 'OK', 'Error')
}

# The BIOS command needs admin rights
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Show-Error 'Quick Mode Switcher needs administrator rights. Run it from an Administrator PowerShell, or install it with Install-QuickModeSwitcher.ps1.'
    exit 1
}

# Only one copy at a time
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\QuickModeSwitcher', [ref]$created)
if (-not $created) {
    Write-Host 'Quick Mode Switcher is already running; look for its icon in the taskbar tray.'
    exit
}

# Index = BIOS value
$modeNames = @('Performance', 'Balanced', 'Cool', 'Quiet', 'Power Saver')
$letters   = @('P', 'B', 'C', 'Q', 'S')
$colors    = @('#D9480F', '#1971C2', '#0C8599', '#2B8A3E', '#495057')   # dark enough for a white letter

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
if (-not $script:inst -or -not $script:inCls) {
    Show-Error "This laptop doesn't have HP's BIOS mode interface, so Quick Mode Switcher can't work here. tools\Test-Compatibility.ps1 shows details."
    exit 1
}

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

# Returns the mode (0-4), or -1 if the reply doesn't look like the one Quick Mode Switcher expects
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
# Drawn at the tray's actual icon size. The letter is centered on its real outline (not the font's
# text box, which includes empty space), and sized to the height of a capital H so all letters match.
$script:iconSize = [Math]::Max(16, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)

function New-ModeIcon([string]$letter, [string]$hex) {
    $size = $script:iconSize
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Circle, with a slightly darker rim so it stands out on both light and dark taskbars
    $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $rim   = [System.Drawing.Color]::FromArgb(255, [int]($color.R * 0.65), [int]($color.G * 0.65), [int]($color.B * 0.65))
    $brush = New-Object System.Drawing.SolidBrush $color
    $pen   = New-Object System.Drawing.Pen($rim, [float][Math]::Max(1, $size / 16))
    [float]$d = $size - 1
    [float]$w = $pen.Width
    $g.FillEllipse($brush, [float]0, [float]0, $d, $d)
    $g.DrawEllipse($pen, [float]($w / 2), [float]($w / 2), [float]($d - $w), [float]($d - $w))

    # Letter
    $family = New-Object System.Drawing.FontFamily 'Segoe UI'
    $style  = [int][System.Drawing.FontStyle]::Bold
    $fmt    = [System.Drawing.StringFormat]::GenericTypographic
    $ref = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ref.AddString('H', $family, $style, 100, (New-Object System.Drawing.PointF(0, 0)), $fmt)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddString($letter, $family, $style, 100, (New-Object System.Drawing.PointF(0, 0)), $fmt)
    $rb = $ref.GetBounds()
    $lb = $path.GetBounds()
    $scale = ($size * 0.52) / $rb.Height
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate([float]($size / 2), [float]($size / 2))                               # 3. move to the icon's center
    $m.Scale([float]$scale, [float]$scale)                                             # 2. scale to size
    $m.Translate([float](-($lb.X + $lb.Width / 2)), [float](-($rb.Y + $rb.Height / 2)))  # 1. center the letter at 0,0
    $path.Transform($m)
    $g.FillPath([System.Drawing.Brushes]::White, $path)

    $g.Dispose(); $brush.Dispose(); $pen.Dispose(); $path.Dispose(); $ref.Dispose(); $m.Dispose(); $family.Dispose()
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [void][QuickModeSwitcher.Native]::DestroyIcon($h)
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
$script:userPicked = $false   # set once a mode is picked from the menu

function Show-Warning([string]$text) {
    $script:tray.ShowBalloonTip(6000, 'Quick Mode Switcher', $text, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Update-State {
    $m = Read-Mode
    # One failed read can be a blip (for example right after waking from sleep), so try once more
    if ($m -lt 0) { Start-Sleep -Milliseconds 500; $m = Read-Mode }
    $script:current = $m
    $ok = $m -ge 0
    for ($i = 0; $i -lt 5; $i++) {
        $script:items[$i].Checked = ($i -eq $m)
        $script:items[$i].Enabled = $ok
    }
    if ($ok) {
        $script:tray.Icon = $script:icons[$m]
        $script:tray.Text = "Quick Mode Switcher: $($modeNames[$m])"
        $script:warned = $false
    } else {
        $script:tray.Icon = $script:warnIcon
        $script:tray.Text = 'Quick Mode Switcher: BIOS reply not recognized'
        if (-not $script:warned) {
            $script:warned = $true
            Show-Warning 'The BIOS reply did not look like the one Quick Mode Switcher expects, so switching is off. Run tools\Get-ModeValues.ps1 to see what changed.'
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

# Switch back to the mode picked in this menu if something else changed it
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
    $it.add_Click({ param($s, $e) $script:userPicked = $true; Set-Mode ([int]$s.Tag) })
    [void]$script:menu.Items.Add($it)
    $script:items += $it
}
[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem('Re-apply my mode at sign-in')
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

# ---------- Keeping your mode ----------
# My HP's background process (HP.SystemControl.Background.exe) re-applies My HP's own setting when the
# charger is plugged in or unplugged, several times over the first ~5 seconds. Switching back right away
# just starts a back-and-forth, so after each such event, wait until it's done, switch back once, and
# check again later in case it was slow. The same checks run after waking from sleep and after login,
# in case My HP re-applies its setting then too. Without My HP installed, they never have to act.
$checkAfter = @{
    power   = @(7, 12, 20)            # seconds after the event
    resume  = @(7, 12, 20)
    startup = @(7, 12, 20, 40, 60)    # HP's background apps can start late after login
}
$script:eventKind = $null
$script:eventAt   = $null
$script:checkIdx  = 0
$script:lastPower = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
$script:lastTick  = Get-Date

function Start-Checks([string]$kind) {
    $script:eventKind = $kind
    $script:eventAt   = Get-Date
    $script:checkIdx  = 0
}

function Invoke-Check([bool]$isLast) {
    if ($script:eventKind -eq 'startup' -and -not $script:settings.restoreAtLogin -and -not $script:userPicked) {
        # Not re-applying at login: the mode the laptop started in (My HP's setting) is the one to keep,
        # unless a mode has been picked from the menu since
        Update-State
        if ($script:current -ge 0 -and $script:current -ne $script:settings.lastMode) {
            $script:settings.lastMode = $script:current
            Save-Settings
        }
    } else {
        Restore-ChosenMode $isLast   # warn only if the last check fails
    }
}

$script:powerTimer = New-Object System.Windows.Forms.Timer
$script:powerTimer.Interval = 500
$script:powerTimer.add_Tick({
    $now = Get-Date
    # The timer doesn't run during sleep, so a long gap between ticks means the laptop just woke up
    if (($now - $script:lastTick).TotalSeconds -gt 10) { Start-Checks 'resume' }
    $script:lastTick = $now

    $p = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
    if ($p -ne $script:lastPower) {
        $script:lastPower = $p
        Start-Checks 'power'
    }

    if ($script:eventAt) {
        $delays = $checkAfter[$script:eventKind]
        if ($script:checkIdx -lt $delays.Count -and ($now - $script:eventAt).TotalSeconds -ge $delays[$script:checkIdx]) {
            $script:checkIdx++
            Invoke-Check ($script:checkIdx -eq $delays.Count)
        }
    }
})

# Refresh the icon every 30 seconds in case something else changes the mode
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 30000
$script:timer.add_Tick({ Update-State })

# ---------- Start ----------
# Right after login the BIOS interface can take a moment, so retry the first read briefly
for ($try = 0; $try -lt 5 -and (Read-Mode) -lt 0; $try++) { Start-Sleep -Seconds 2 }

$script:tray.Icon = $script:warnIcon
$script:tray.Visible = $true
Update-State

if ($script:current -ge 0) {
    if ($script:settings.lastMode -lt 0 -or -not $script:settings.restoreAtLogin) {
        # First run, or not re-applying at login: keep the mode the laptop started in
        $script:settings.lastMode = $script:current
        Save-Settings
    } elseif ($script:settings.lastMode -ne $script:current) {
        Set-Mode $script:settings.lastMode
    }
}
Start-Checks 'startup'

$script:timer.Start()
$script:lastTick = Get-Date
$script:powerTimer.Start()
[System.Windows.Forms.Application]::Run()

$script:powerTimer.Stop()
$script:timer.Stop()
$script:tray.Dispose()
$script:mutex.ReleaseMutex()
