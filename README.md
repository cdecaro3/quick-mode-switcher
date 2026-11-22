# HP Quick Modes

A small system-tray switcher for HP laptop modes (Performance, Balanced, Cool, Quiet, Power Saver). It replaces that one feature of the My HP app without the app's background load.

> **Status:** the BIOS read and write commands are verified on the hardware below. The tray app itself is not tested yet.

## Tested hardware

- HP Spectre x360 14-eu000 (board `8C15`), Intel Core Ultra 7 155H, Windows 11
- BIOS updated past F.16 (Nov 2026); mode values were identical before and after the update

## How it works

My HP's modes are a single BIOS setting exposed through HP's WMI interface (`root\wmi`, class `hpqBIntM`). The tool uses command type `0x4C`, the same one the Linux kernel's `hp-wmi` driver uses.

| Value | Mode |
|---|---|
| `00` | Performance |
| `01` | Balanced |
| `02` | Cool |
| `03` | Quiet |
| `04` | Power Saver |

- **Read:** `Command = 1`, method `hpqBIOSInt128`. The first byte of the reply is the mode. The second byte (`10` or `11`) is a status flag that changes on its own; it is ignored.
- **Write:** `Command = 2`, method `hpqBIOSInt0`, data `[mode] 00 00 00`.
- Changing the mode this way does not touch Windows' power mode, and My HP shows the new mode.

## Files

| File | What it does |
|---|---|
| `HPQuickModes.ps1` | The tray app. Left- or right-click the icon for the mode menu. |
| `Install-HPQuickModes.ps1` | Copies the app to Program Files and registers a logon task with highest privileges, so it starts without an admin prompt. `-Uninstall` removes both. |
| `tools/hp-mode-check.ps1` | Read-only diagnostic: model, BIOS interface, current mode, HP services. |
| `tools/hp-mode-sample.ps1` | Read-only: records the BIOS value for each mode you pick in My HP. |
| `tools/hp-mode-write-test.ps1` | Guided write test that asks before each change and ends on the starting mode. |

## Use

All commands run in an Administrator PowerShell from the repo folder.

Try it without installing:

```
powershell -ExecutionPolicy Bypass -File .\HPQuickModes.ps1
```

Install (starts at login):

```
powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1
```

Uninstall:

```
powershell -ExecutionPolicy Bypass -File .\Install-HPQuickModes.ps1 -Uninstall
```

## Safety

- Sends only the read and write commands above, and only values `00`–`04`.
- Refuses to switch if the BIOS reply doesn't match what was verified (return code 0, signature `PASS`, first byte `00`–`04`), for example after a future BIOS update. The icon turns into a red `!`.
- Reads the mode back after every switch and warns if it didn't take.
- The installed copy lives in Program Files, so only admins can change the script that runs with admin rights.
- "Re-apply last mode at login" is on by default, in case the BIOS resets the mode at startup.

## Notes

Each mode changes several things at once (fans, power limits and more). This tool sets the BIOS mode only. If My HP also does something on its own when you pick a mode, such as dimming the screen in Power Saver, the tool won't do that yet; to be checked during testing.

Not affiliated with or endorsed by HP. Mode values come from testing on the hardware above and from the Linux kernel's `drivers/platform/x86/hp/hp-wmi.c`; other HP models may use different values (Omen and Victus laptops do).
