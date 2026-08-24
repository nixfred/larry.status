# Changelog

## 0.4.1 — 2026-08-24
- Fix: interactive sessions whose *prompt text* contained `run`/`exec`/`mcp`/`serve` (e.g. `claude "please run the tests"`) were silently excluded. Filter now judges only the subcommand token and real flags (`--filter-of` test hook, 13 cases).
- Fix: name length was counted in bytes under quickshell's C locale; UTF-8 prompts could be over-truncated or split mid-character. Collector now runs under `C.UTF-8`.
- Fix: async titler cap prompt at 600 chars (pasted walls of text); recover from a stale `.lock` (>2 min) left by a killed titler.

## 0.4.0 — 2026-08-22
- Agents on Deck now tracks **every agent CLI on the host**: Claude Code, Codex, OpenCode, Grok, Gemini, Copilot, aider (comm/argv detection, helper processes de-duplicated by ancestry).
- **Crisp session names**: each session is matched to its own transcript by start time (±20s) and named from the first real prompt → then upgraded to a 3–5 word title from local gemma2 (Ollama, async, cached in `$XDG_RUNTIME_DIR/larry.status`). OpenCode uses its own `session.title`; Grok uses `prompt_history.jsonl`; Claude falls back to `current-work` task title → hook session-names → dir. `title_src` field says which.
- `LARRY_STATUS_NO_LLM=1` / `--no-llm` disables the LLM step; `LARRY_STATUS_LLM_MODEL` overrides the model.
- Fix: Codex rollout session_meta line is >2KB — read the whole first line.
- Panel: per-agent glyphs and labels.

## 0.3.3 — 2026-08-22
- Perf: panel hero face no longer animates while the panel is closed (it was animating off-screen).
- Perf: bar eye pulse is a stepped ~10 fps timer instead of a continuous 60 fps animation; dropped the halo opacity Behavior. quickshell CPU 17% → ~13.5% (no-animation floor ~11.5%).
- Known: "IpcHandler … another handler is registered" warnings — Omarchy instantiates bar widgets twice; same as rift; harmless.

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
