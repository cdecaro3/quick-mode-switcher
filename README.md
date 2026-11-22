# HP Quick Modes

A lightweight system-tray switcher for HP laptop modes: Performance, Balanced, Cool, Quiet and Power Saver. Click the tray icon, pick a mode, done. It does this one job of the My HP app without My HP's background processes.

Made for the **HP Spectre x360 14 (2024, 14-eu0000 series, Intel Core Ultra)**. It may work on other HP laptops that use the same BIOS interface; see [Other HP laptops](#other-hp-laptops).

> **Status:** early. The BIOS commands are verified on the laptop above; the tray app is still being tested.

## Features

- Tray icon showing the current mode as a colored letter (P, B, C, Q, S)
- Left- or right-click for a menu of all five modes, with the current one checked
- Keeps your mode when you plug in or unplug, wake from sleep or sign in, even if My HP is still installed (see [My HP](#my-hp))
- Starts at sign-in without an admin prompt
- Optionally re-applies your last mode at sign-in
- Refuses to switch if the BIOS reply looks unfamiliar, and warns if a switch doesn't take

## Requirements

- Windows 11 with Windows PowerShell 5.1, which is built in (Windows 10 is untested)
- A Windows administrator account: the BIOS command needs admin rights, so the app runs with them

## Install

1. On this page, click **Code → Download ZIP**, then extract it (or `git clone` the repo).
2. Right-click the Start button and choose **Terminal (Admin)**.
3. Go to the extracted folder, for example:
   ```
   cd "$env:USERPROFILE\Downloads\hp-quick-modes-main"
   ```
4. Run the installer:
   ```
   powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1
   ```

The installer checks that your laptop answers the mode command, copies the app to `C:\Program Files\HPQuickModes`, and creates a scheduled task, "HP Quick Modes", that starts it at sign-in with admin rights. The icon may land in the taskbar's `^` overflow area; drag it onto the taskbar to keep it visible.

To try it without installing, run this from the same folder instead. It runs until you choose Exit from its menu.

```
powershell -ExecutionPolicy Bypass -File .\HPQuickModes.ps1
```

To update, download the new version and run the installer again. Your settings are kept.

To uninstall:

```
powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1 -Uninstall
```

## Other HP laptops

Check yours before installing, in this order (the scripts are described under [Tools](#tools)):

1. `Test-Compatibility.ps1` says whether the BIOS supports the mode command.
2. `Get-ModeValues.ps1` checks that each mode in My HP uses the value in the [table below](#how-it-works).
3. `Test-ModeSwitch.ps1` changes the mode once and switches back, asking before each step.

HP Quick Modes won't work on Omen and Victus laptops, which use different values. Other tools cover those models.

## How it works

The modes are a single BIOS setting exposed through HP's WMI interface (`root\wmi`, class `hpqBIntM`), command type `0x4C`. It's the same setting My HP changes, and the same command the Linux kernel's `hp-wmi` driver uses.

| Value | Mode |
|---|---|
| `00` | Performance |
| `01` | Balanced |
| `02` | Cool |
| `03` | Quiet |
| `04` | Power Saver |

- **Read:** `Command = 1`, method `hpqBIOSInt128`. The first byte of the reply is the mode; the second is a status flag that changes on its own and is ignored.
- **Write:** `Command = 2`, method `hpqBIOSInt0`, data `[mode] 00 00 00`.

## My HP

You don't need to uninstall My HP, but there's one interaction to know about. Its background process, `HP.SystemControl.Background.exe`, re-applies My HP's last pick when the charger is plugged in or unplugged, several times over the first 5 seconds or so. HP Quick Modes waits for it to finish and then switches back to your mode, so you'll see My HP's pick for about 7 seconds.

**If you keep My HP, set it to the mode you want the laptop to start in.** Balanced is a sensible choice. The laptop starts in My HP's setting after a restart, and you'll see it for those few seconds after plugging in or unplugging. With "Re-apply last mode at login" on, HP Quick Modes then switches to your last pick; with it off, it keeps My HP's mode until you pick one in its menu.

Picking a mode in HP Quick Modes doesn't change My HP's setting. Picking one in My HP works, but only until the next plug/unplug, wake from sleep or restart; after that, HP Quick Modes switches back to the mode picked in its menu.

To remove My HP:

1. Settings → Apps → Installed apps → **myHP** → Uninstall.
2. Search Start for **Change device installation settings** and choose **No**. HP delivers My HP through driver packages from Windows Update, and this setting should keep it from being reinstalled automatically.

If My HP comes back anyway, HP Quick Modes keeps working; you'll just see the brief switch again.

To see this for yourself, use `Watch-PlugUnplug.ps1`. If the mode changes on plug/unplug on another model, `Find-ModeChanger.ps1` finds which HP program is doing it.

## Tools

Helper scripts in `tools/`, for checking compatibility and seeing what's going on. Each one runs in an Administrator PowerShell from the repo folder, for example:

```
powershell -ExecutionPolicy Bypass -File .\tools\Test-Compatibility.ps1
```

Each copies its results to the clipboard when it finishes.

| Script | What it does | Changes anything? |
|---|---|---|
| `Test-Compatibility.ps1` | Shows the model and BIOS, whether the BIOS answers the mode command, and the HP software running with its memory use. | No |
| `Get-ModeValues.ps1` | You pick each mode in My HP and type its name; it checks the BIOS value against the table above. Needs My HP. | No |
| `Test-ModeSwitch.ps1` | Re-sends the current mode, switches to another, then switches back. Asks before each step. | Yes, and switches back |
| `Watch-PlugUnplug.ps1` | Logs mode changes as you plug in and unplug, and how long HP Quick Modes takes to switch back. | No |
| `Find-ModeChanger.ps1` | Stops one HP app's programs at a time and watches plug/unplug, to find which one changes the mode. Asks before each app. | Stops programs until the next restart |

## Troubleshooting

- **No icon after installing.** Check the taskbar's `^` overflow area. If it isn't there, run `HPQuickModes.ps1` directly from an Administrator PowerShell to see any error, or look at the "HP Quick Modes" task in Task Scheduler.
- **Nothing happens when I run `HPQuickModes.ps1`.** It's already running, probably the installed copy; look for its icon.
- **The icon is a red `!`.** The BIOS reply wasn't what HP Quick Modes expects, for example after a BIOS update, so switching is off. Run `Test-Compatibility.ps1` and `Get-ModeValues.ps1` to see what changed.
- **The mode changes on its own.** That's My HP (see [My HP](#my-hp)). On other models it may be a different HP program; `Find-ModeChanger.ps1` finds it.
- **Settings** are in `settings.json` next to the app, which is `C:\Program Files\HPQuickModes` when installed.

## Safety

- Sends only the read and write commands above, and only values `00`–`04`.
- Checks every reply (return code 0, signature `PASS`, mode `00`–`04`). If one looks wrong, for example after a BIOS update, switching turns off and the icon shows a red `!`.
- Reads the mode back after each switch and warns if it didn't take.
- The installed copy lives in Program Files, so only admins can change the script that runs with admin rights.

## Limitations

- Sets the BIOS mode only. Anything My HP does on top of that, such as Smart Sense's automatic switching or dimming the screen in Power Saver, isn't replicated.
- Memory use is that of a PowerShell process, roughly 50–100 MB.

## Credits

The command and mode values were documented by the Linux kernel's [`hp-wmi` driver](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/hp/hp-wmi.c).

Not affiliated with or endorsed by HP. Use at your own risk.
