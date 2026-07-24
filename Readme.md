# PC Startup Metrics

Generates a self-contained HTML report of Windows boot performance and opens it in the default browser. Reports are saved to the `Reports\` subfolder as `BootReport_yyyy-MM-dd_HHmmss.html`.

## Usage

```powershell
.\Get-BootReport.ps1                     # default: last 20 boots
.\Get-BootReport.ps1 -HistoryCount 50    # more history
```

Reading the Diagnostics-Performance event log requires Administrator rights; the script self-elevates with a UAC prompt if launched unelevated.

A scheduled task named **Boot Report** runs the script automatically at logon (2-minute delay, highest privileges), so a report is produced for every boot.

## What the report shows

| Section | Meaning |
|---|---|
| Last BIOS time | Firmware POST duration (same figure as Task Manager). Current boot only — Windows keeps no POST history. |
| Overall startup time | Windows total boot time (event 100 `BootTime`) = main path + post-boot. |
| Main boot path | Time to a usable desktop (`MainPathBootTime`). |
| Post-boot activity | Background settle time after the desktop appears (`BootPostBootTime`). |
| Phase Breakdown | Per-phase durations from event 100: kernel, drivers, devices, prefetch, Smss (login page appears at its end), critical services, profiles, Explorer (desktop icons appear at its end), post-boot. |
| Main Path Detail | Fine-grained event 100 v2 stages: OS loader, PnP init, session 0/1 init, session init — other, logon waits. |
| Slow Boot Culprits | Apps/drivers/services/phases Windows flagged as slower than their historical baseline (events 101–110), with total and degradation times. |
| Boot History | One row per boot with type, totals, and BIOS time. Green row = fastest, red = slowest. |

Boot type (Restart / Cold power-up / Fast startup / Resume) comes from Kernel-Boot event 27 plus the preceding User32 event 1074 shutdown reason.

## Data sources

- `Microsoft-Windows-Diagnostics-Performance/Operational` events 100 (boot timing) and 101–110 (degradation culprits). Requires the DPS, WdiServiceHost and WdiSystemHost services to be enabled — debloat tweaks that disable them stop phase data from being logged.
- Registry `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\FwPOSTTime` (Last BIOS time).
- `System` log: Kernel-Boot event 27 (boot type), User32 event 1074 (shutdown reason).

## Notes

- Event 100 is written only after post-boot activity settles (can be minutes after logon). If run early in a boot, the script waits up to 5 minutes for it.
- All event 100 timestamps are UTC; the script converts to local time.
- Event 100 sub-phase fields end in `Time` (e.g. `BootSmssInitTime`), not `Duration` — the extra v2 fields (e.g. `Session0InitDuration`) do use `Duration`.
