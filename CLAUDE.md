# CLAUDE.md

Windows boot-performance reporting project. See `README.md` for usage and data sources.

## Key Files

| File | Description |
|---|---|
| `Get-BootReport.ps1` | Main script: collects boot metrics from event logs + registry, writes and opens an HTML report. Self-elevates via UAC. |
| `README.md` | Usage, report sections, data sources, gotchas. |
| `Reports\` | Generated HTML reports (`BootReport_yyyy-MM-dd_HHmmss.html`); not tracked in git. |

## Project notes

- A scheduled task **Boot Report** (not a file — registered in Task Scheduler) runs the script at logon with a 2-minute delay, highest privileges.
- Reading `Microsoft-Windows-Diagnostics-Performance/Operational` requires elevation; verify field names against real event XML before adding parsing (event 100 sub-phases end in `Time`, v2 detail fields in `Duration`).
- Event 100 `BootStartTime` is UTC — always `.ToLocalTime()` when comparing or displaying.
- Phase data depends on DPS/WdiServiceHost/WdiSystemHost services being enabled.
- Event 100 additionally requires **SysMain** running and the **ReadyBoot autologger** enabled (`HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot\Start` = 1) — debloat tweaks disable these and the log then stays empty forever. `Test-BootTracingEnabled` checks both so the empty-log notice distinguishes “tracing off” from “log just cleared”.
- The script is plain ASCII, CRLF, **no BOM** — keep it that way; editors that add a UTF-8 BOM show up as a spurious first-line diff.
