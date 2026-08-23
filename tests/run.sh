#!/usr/bin/env bash
# larry.status test suite — static checks + live collector contract.
# Usage: tests/run.sh          (exit 0 = all pass)
set -u
cd "$(dirname "$0")/.."
fail=0; pass=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; }

echo "static:"
for f in *.qml; do
  o=$(grep -o '{' "$f" | wc -l); c=$(grep -o '}' "$f" | wc -l)
  [ "$o" = "$c" ] && ok "$f braces balanced ($o)" || bad "$f braces unbalanced ($o/$c)"
done
grep -q '"focuswindow"' BarWidget.qml Panel.qml && bad "legacy focuswindow syntax present (Hyprland ≥0.56 needs hl.dsp.focus Lua)" || ok "focus uses hl.dsp.focus"
grep -q "pgrep -f 'mpv" BarWidget.qml && bad "pgrep -f 'mpv' self-matches its sh -c wrapper" || ok "speaking pgrep uses [m]pv"
jq -e '.id=="larry.status" and .entryPoints.barWidget=="BarWidget.qml"' manifest.json >/dev/null && ok "manifest valid" || bad "manifest invalid"
v=$(jq -r .version manifest.json); grep -q "$v" CHANGELOG.md 2>/dev/null && ok "CHANGELOG mentions $v" || bad "CHANGELOG missing $v"
bash -n larry_sessions.sh && ok "larry_sessions.sh parses" || bad "larry_sessions.sh syntax error"

echo "state parser:"
while IFS='|' read -r title want; do
  got=$(./larry_sessions.sh --state-of "$title")
  [ "$got" = "$want" ] && ok "'$title' → $want" || bad "'$title' → $got (want $want)"
done <<'CASES'
⚙️ Processing request.|working
🧠 Thinking about the plugin|thinking
❓ Which branch?|question
⠧ pi|working
✓ Larry Session|idle
pi|idle
|idle
plugin.latency.intern...|idle
CASES

echo "collector:"
out=$(timeout 10 ./larry_sessions.sh) || { bad "collector exited non-zero"; out='[]'; }
jq -e 'type=="array"' <<<"$out" >/dev/null && ok "emits JSON array" || bad "not a JSON array: ${out:0:80}"
n=$(jq length <<<"$out")
if [ "$n" -gt 0 ]; then
  jq -e 'all(.[]; has("pid") and has("sid") and has("name") and has("cwd") and has("state") and has("agent") and has("attached") and has("address") and has("workspace") and has("etimes"))' <<<"$out" >/dev/null \
    && ok "all $n rows have required keys" || bad "rows missing keys"
  jq -e 'all(.[]; .state|IN("working","thinking","question","idle"))' <<<"$out" >/dev/null && ok "states valid" || bad "invalid state value"
  jq -e 'all(.[]; .agent|IN("claude","codex"))' <<<"$out" >/dev/null && ok "agents valid" || bad "invalid agent value"
  jq -e 'all(.[]; (.attached|not) or (.address|startswith("0x")))' <<<"$out" >/dev/null && ok "attached rows have hypr address" || bad "attached row without address"
  jq -e 'all(.[]; .name != "")' <<<"$out" >/dev/null && ok "every row named" || bad "unnamed row"
  jq -e '[.[].etimes] == ([.[].etimes]|sort)' <<<"$out" >/dev/null && ok "sorted newest-first" || bad "not sorted by etimes"
  jq -e 'all(.[]; .pid > 0) and ([.[].pid]|unique|length) == length' <<<"$out" >/dev/null && ok "pids unique" || bad "duplicate pids"
  if [ -n "${CLAUDE_SESSION_ID:-}" ] || pgrep -x claude >/dev/null; then
    jq -e 'any(.[]; .agent=="claude")' <<<"$out" >/dev/null && ok "sees a running claude session" || bad "claude running but not listed"
  fi
else
  echo "  (no agents running — row checks skipped)"
fi

echo "live widget (skipped if shell not running):"
if command -v omarchy-shell >/dev/null && st=$(timeout 5 omarchy-shell larry.status status 2>/dev/null); then
  grep -q '^mood=' <<<"$st" && ok "ipc status: $st" || bad "ipc status odd: $st"
  timeout 5 omarchy-shell larry.status sessions | jq -e 'type=="array"' >/dev/null && ok "ipc sessions is JSON" || bad "ipc sessions not JSON"
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
