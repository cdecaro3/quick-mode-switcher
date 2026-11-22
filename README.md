# HP Quick Modes

A lightweight system-tray switcher for HP laptop modes: Performance, Balanced, Cool, Quiet and Power Saver. Click the tray icon, pick a mode, done. It does this one job of the My HP app without My HP's background processes.

Made for the **HP Spectre x360 14 (2024, 14-eu0000 series, Intel Core Ultra)**. It may work on other HP laptops that use the same BIOS interface; see [Other HP laptops](#other-hp-laptops).

> **Status:** early. The BIOS commands are verified on the laptop above; the tray app is still being tested.

## Features

- Tray icon showing the current mode as a colored letter (P, B, C, Q, S)
- Left- or right-click for a menu of all five modes, with the current one checked
- Keeps your mode when you plug in or unplug, even if My HP is still installed (see [My HP](#my-hp))
- Starts at login without an admin prompt
- Optionally re-applies your last mode at login
- Refuses to switch if the BIOS reply looks unfamiliar, and warns if a switch doesn't take

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- Administrator rights to install

## Install

Download or clone the repo, then run in an Administrator PowerShell from the repo folder:

```
powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1
```

This copies the app to `C:\Program Files\HPQuickModes` and creates a scheduled task, "HP Quick Modes", that starts it at login with admin rights. The icon may land in the taskbar's `^` overflow area; drag it onto the taskbar to keep it visible.

To try it without installing:

```
powershell -ExecutionPolicy Bypass -File .\HPQuickModes.ps1
```

To uninstall:

```
powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1 -Uninstall
```

## Other HP laptops

Check yours before installing. These scripts are in `tools/` and run the same way as above:

1. `hp-mode-check.ps1` is read-only. Your laptop is likely compatible if the `read 0x4C` lines show `rwReturnCode=0`.
2. `hp-mode-sample.ps1` is read-only. It records the BIOS value for each mode as you switch in My HP. The first byte should match the table below.
3. `hp-mode-write-test.ps1` changes the mode once and switches back, asking before each step.

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

To remove My HP:

1. Settings → Apps → Installed apps → **myHP** → Uninstall.
2. Search Start for **Change device installation settings** and choose **No**. HP delivers My HP through driver packages from Windows Update, and this setting should keep it from being reinstalled automatically.

If My HP comes back anyway, HP Quick Modes keeps working; you'll just see the brief switch again.

To see this in action, run `tools/hp-quick-modes-test.ps1` (read-only) while HP Quick Modes is running, then plug in and unplug a few times. It shows each switch and times how long My HP's pick lasts before HP Quick Modes switches back.

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
