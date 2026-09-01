# PC Startup Metrics

Generates a self-contained HTML report of Windows boot performance and opens it in the default browser. Reports are saved to the `Reports\` subfolder as `BootReport_yyyy-MM-dd_HHmmss.html`.

## Usage

```powershell
.\Get-BootReport.ps1                     # default: reads last 20 boots' events
.\Get-BootReport.ps1 -HistoryCount 50    # more history
```

`-HistoryCount` controls how many event-100 records are read from the event log (for the Latest Boot, Phase Breakdown, and degradation-culprit matching). The Boot History table always displays only the most recent 10 of those, regardless of `-HistoryCount`.

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
| Boot History | Last 10 boots (of the `-HistoryCount` read from the log) with type, totals, and BIOS time. Green row = fastest, red = slowest among those shown. |

Boot type (Restart / Cold power-up / Fast startup / Resume) comes from Kernel-Boot event 27 plus the preceding User32 event 1074 shutdown reason.

## Data sources

- `Microsoft-Windows-Diagnostics-Performance/Operational` events 100 (boot timing) and 101–110 (degradation culprits). Requires the DPS, WdiServiceHost and WdiSystemHost services to be enabled — debloat tweaks that disable them stop phase data from being logged.
- Event 100 itself is WDI's analysis of the **ReadyBoot ETW trace**, which the ReadyBoot autologger captures and **SysMain** finalises. If either is off, the log stays empty permanently — see [No boot performance data](#no-boot-performance-data).
- Registry `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\FwPOSTTime` (Last BIOS time).
- `System` log: Kernel-Boot event 27 (boot type), User32 event 1074 (shutdown reason).

## No boot performance data

When no event 100 records are found the report shows a notice, and there are two very different causes:

| Cause | What the notice says | Fix |
|---|---|---|
| **Boot tracing switched off** — SysMain disabled/stopped, or the ReadyBoot autologger's `Start` value is not 1 | Names the specific culprit(s) and the commands to fix them | `Set-Service SysMain -StartupType Automatic; Start-Service SysMain`, set `HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot\Start` to `1`, then reboot |
| **Log simply cleared** — tracing is healthy, the log was wiped | Says tracing looks enabled and data returns after the next boot | Nothing; reboot and re-run |

Debloat/“optimiser” scripts commonly disable SysMain and the ReadyBoot autologger, which silently kills all boot timing data.

## Notes

- Event 100 is written only after post-boot activity settles (can be minutes after logon). If run early in a boot, the script waits up to 5 minutes for it.
- All event 100 timestamps are UTC; the script converts to local time.
- Event 100 sub-phase fields end in `Time` (e.g. `BootSmssInitTime`), not `Duration` — the extra v2 fields (e.g. `Session0InitDuration`) do use `Duration`.
