# PC Startup Metrics — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

- (none recorded yet)

## RULED-OUT THEORIES

- (none recorded yet)

## PROJECT CONVENTIONS

- (none recorded yet)

## CHANGE LOG

Newest first. Format: `- YYYY-MM-DD — what changed`.

- 2026-09-01 — Boot History table capped to the most recent 10 boots (fastest/slowest highlighting now computed over those 10, not the full `-HistoryCount` fetch, which stays at 20 by default).
- 2026-09-01 — Report notice now distinguishes "current boot's event 100 not written yet" from "boot tracing has stopped logging" (stale older events exist but not for this boot); names the last stale timestamp and points at SysMain/ReadyBoot.
- 2026-08-02 — Added MEMORY.md (standard project structure).
