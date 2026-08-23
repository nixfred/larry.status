#!/usr/bin/env bash
# larry_sessions.sh — enumerate live Claude Code (Larry) sessions on this host.
# Emits a JSON array for the larry.status Omarchy plugin:
#   [{pid, sid, name, cwd, project, state, agent, attached, title, kittyPid, address, workspace, etimes}]
# state ∈ working | thinking | question | idle ; agent ∈ claude | codex
# attached=false → daemon-hosted session with no terminal window on this host (can't focus)
#
# Sources (all read-only):
#   /proc               — claude processes, cwd, parent chain → kitty pid
#   hyprctl clients -j  — kitty pid → window address, workspace, live title
#   ~/.claude/MEMORY/STATE/session-names.json   — auto-generated session names
#   ~/.claude/MEMORY/STATE/kitty-sessions/*.json — sid ↔ kitty socket mapping
set -u
STATE="${HOME}/.claude/MEMORY/STATE"
NAMES="${STATE}/session-names.json"
KSESS="${STATE}/kitty-sessions"

command -v jq >/dev/null 2>&1 || { echo '[]'; exit 0; }

clients="$(hyprctl clients -j 2>/dev/null || echo '[]')"
names="$( [ -r "$NAMES" ] && cat "$NAMES" || echo '{}' )"

# kitty pid → session id (from per-session kitty-sessions files)
kmap='{}'
if [ -d "$KSESS" ]; then
  for f in "$KSESS"/*.json; do
    [ -r "$f" ] || continue
    sid="$(basename "$f" .json)"
    kpid="$(jq -r '.listenOn // ""' "$f" 2>/dev/null | sed -n 's/.*omarchy-kitty-\([0-9]*\)$/\1/p')"
    [ -n "$kpid" ] && kmap="$(jq -c --arg k "$kpid" --arg s "$sid" '. + {($k): $s}' <<<"$kmap")"
  done
fi

kitty_ancestor() { # pid → nearest ancestor whose comm is kitty (or empty)
  local p="$1" c
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$p" != "0" ]; do
    c="$(cat /proc/"$p"/comm 2>/dev/null)" || return 0
    if [ "$c" = "kitty" ]; then echo "$p"; return 0; fi
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)"
  done
}

out='[]'
for pid in $(pgrep -x claude 2>/dev/null; pgrep -x codex 2>/dev/null); do
  argv="$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null)" || continue
  comm="$(cat /proc/"$pid"/comm 2>/dev/null)"
  agent="claude"; [ "$comm" = "codex" ] && agent="codex"
  case " $argv " in
    *" daemon "*|*"bg-pty-host"*|*"bg-spare"*|*" -p "*|*"--print"*|*" exec "*|*"mcp-server"*) continue ;;
  esac
  # interactive = has a tty, OR is a daemon-hosted Claude session (bg-pty-host parent)
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  pcomm="$(tr '\0' ' ' </proc/"$(awk '{print $4}' /proc/"$pid"/stat 2>/dev/null)"/cmdline 2>/dev/null)"
  if [ -z "$tty" ] || [ "$tty" = "?" ]; then
    case "$pcomm" in *bg-pty-host*) ;; *) continue ;; esac
  fi
  etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  cwd="$(readlink /proc/"$pid"/cwd 2>/dev/null || echo "")"
  sid="$(sed -n 's/.*--session-id \([0-9a-f-]\{36\}\).*/\1/p' <<<"$argv")"
  kpid="$(kitty_ancestor "$pid")"
  [ -z "$sid" ] && [ -n "$kpid" ] && sid="$(jq -r --arg k "$kpid" '.[$k] // ""' <<<"$kmap")"
  name=""
  [ -n "$sid" ] && name="$(jq -r --arg s "$sid" '.[$s] // ""' <<<"$names")"
  project="$(basename "${cwd:-/}")"
  [ -z "$name" ] && name="$project"
  [ "$agent" = "codex" ] && [ -z "$sid" ] && sid="codex-$pid"

  addr="" ws="" title=""
  if [ -n "$kpid" ]; then
    read -r addr ws title < <(jq -r --argjson p "$kpid" \
      '[.[] | select(.pid == $p)] | first // empty | "\(.address) \(.workspace.id) \(.title)"' <<<"$clients")
  fi
  state="idle"
  case "$title" in
    ❓*) state="question" ;;
    🧠*) state="thinking" ;;
    ⚙*|⠋*|⠙*|⠹*|⠸*|⠼*|⠴*|⠦*|⠧*|⠇*|⠏*|⠸*) state="working" ;;
    *" Processing "*|*"Processing request"*) state="working" ;;
  esac
  [ -z "$addr" ] && attached=false || attached=true

  out="$(jq -c \
    --argjson pid "$pid" --arg sid "$sid" --arg name "$name" --arg cwd "$cwd" \
    --arg project "$project" --arg state "$state" --arg title "$title" \
    --arg kpid "${kpid:-0}" --arg addr "$addr" --arg ws "${ws:-0}" --arg et "${etimes:-0}" \
    --arg agent "$agent" --argjson attached "$attached" \
    '. + [{pid:$pid, sid:$sid, name:$name, cwd:$cwd, project:$project, state:$state, agent:$agent,
           attached:$attached, title:$title, kittyPid:($kpid|tonumber), address:$addr,
           workspace:($ws|tonumber? // 0), etimes:($et|tonumber? // 0)}]' <<<"$out")"
done

# newest first (smallest etimes)
jq -c 'sort_by(.etimes)' <<<"$out"
