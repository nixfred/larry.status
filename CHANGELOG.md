# Changelog

## 0.3.2 — 2026-08-22
- Change: red (alert) face only on a confirmed service outage. Missing or stale heartbeat now dims the face instead of turning it red (false alarms after boot/resume).
- Collector: `state_from_title()` factored out + `--state-of "<title>"` test hook; unit cases in tests.

## 0.3.1 — 2026-08-22
- Fix: `h` heartbeat hotkey never fired — PanelKeyCatcher consumes h/j/k/l as movement. Hotkey is now `c` (check).
- New: keyboard navigation of Agents on Deck — `j`/`k` (or arrows) move a cursor, Enter/Space jumps.
- Fix: busy dot could stay dim after its pulse animation stopped.
- Fix: guard against non-array collector output.
- Tests: `tests/run.sh` (static checks + collector contract + live IPC).

## 0.3.0 — 2026-08-22
- CyberFace: Larry's face drawn live in QML (bar + panel hero) with moods sleep/idle/thinking/working/question/speaking/alert.
- Agents on Deck: live Claude Code + Codex sessions, click / 1–9 / right-click to jump to the window.
- Hyprland ≥0.56 focus via `hl.dsp.focus({ window = "address:…" })`.

## 0.2.0 — 2026-08-20
- Control panel: services, fleet, brain, actions.
