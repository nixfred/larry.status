#!/usr/bin/env bash
# larry_sessions.sh — enumerate live AI-agent sessions on this host for larry.status.
#
# Agents detected: claude (Claude Code), codex (OpenAI Codex), opencode, grok (xAI),
# gemini (Google), copilot (GitHub), aider. Anything interactive with a terminal, plus
# daemon-hosted Claude sessions (bg-pty-host) which are listed as detached.
#
# Output: JSON array, newest first:
#   [{pid, sid, name, title_src, cwd, project, state, agent, attached, title,
#     kittyPid, address, workspace, etimes}]
#   state ∈ working | thinking | question | idle
#   name  = crisp session title: LLM title (gemma2 via Ollama, async, cached) →
#           first real prompt (trimmed) → agent's own title → project dir
#
# Sources (read-only): /proc, ps, hyprctl clients -j,
#   ~/.claude/MEMORY/STATE/{session-names.json,kitty-sessions/,current-work-*.json},
#   ~/.claude/projects/**/<sid>.jsonl, ~/.codex/sessions/**/rollout-*.jsonl,
#   ~/.local/share/opencode/opencode.db, ~/.grok/sessions/<urlenc cwd>/prompt_history.jsonl
#
# Test hooks:  --state-of "<title>"   --trim "<text>"   --no-llm
set -u
export LC_ALL=C.UTF-8      # quickshell spawns us with a C locale; names must be counted in chars, not bytes
STATE="${HOME}/.claude/MEMORY/STATE"
CACHE="${XDG_RUNTIME_DIR:-/tmp}/larry.status"
NAME_MAX=44
LLM_MODEL="${LARRY_STATUS_LLM_MODEL:-gemma2:latest}"
LLM=1; [ "${LARRY_STATUS_NO_LLM:-0}" = 1 ] && LLM=0
mkdir -p "$CACHE/names" "$CACHE/llm" 2>/dev/null

# ------------------------------------------------------------------ helpers
state_from_title() {
  case "$1" in
    ❓*) echo question ;;
    🧠*) echo thinking ;;
    ⚙*|⠋*|⠙*|⠹*|⠸*|⠼*|⠴*|⠦*|⠧*|⠇*|⠏*) echo working ;;
    *"Processing request"*) echo working ;;
    *) echo idle ;;
  esac
}
# Collapse whitespace, strip quotes, cap length at a word boundary with an ellipsis.
trim_name() {
  local t
  t="$(printf '%s' "$1" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')"
  t="${t#\"}"; t="${t%\"}"
  if [ "${#t}" -gt "$NAME_MAX" ]; then
    t="$(printf '%s' "$t" | cut -c1-"$NAME_MAX" | sed -E 's/ +[^ ]*$//; s/[[:punct:] ]+$//')…"
  fi
  printf '%s' "$t"
}
# keep/skip decision for a candidate process. Only the SUBCOMMAND (2nd token) and real
# flags are judged — never words inside a quoted prompt ("please run the tests").
filter_args() { # args → keep | skip
  local sub; sub="$(awk '{print $2}' <<<"$1")"
  case "$sub" in
    daemon|exec|mcp|mcp-server|serve|run|login|logout|update|doctor|config|install|bg-pty-host|bg-spare|--version|-v|--help|-h|-p|--print) echo skip; return ;;
  esac
  case " $1 " in *" bg-pty-host "*|*" --bg-pty-host "*|*" --bg-spare "*|*" -p "*|*" --print "*|*" mcp-server "*) echo skip; return ;; esac
  echo keep
}
case "${1:-}" in
  --state-of) state_from_title "${2:-}"; exit 0 ;;
  --filter-of) filter_args "${2:-}"; exit 0 ;;
  --trim)     trim_name "${2:-}"; echo; exit 0 ;;
  --no-llm)   LLM=0 ;;
esac
command -v jq >/dev/null 2>&1 || { echo '[]'; exit 0; }

epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }
abs_diff() { local d=$(( $1 - $2 )); echo "${d#-}"; }
start_epoch() { date -d "$(ps -o lstart= -p "$1" 2>/dev/null)" +%s 2>/dev/null || echo 0; }

kitty_ancestor() { # pid → nearest ancestor whose comm is kitty (or empty)
  local p="$1" c
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$p" != "0" ]; do
    c="$(cat /proc/"$p"/comm 2>/dev/null)" || return 0
    if [ "$c" = "kitty" ]; then echo "$p"; return 0; fi
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)"
  done
}
ancestor_in_set() { # pid setfile → 0 if any of up to 4 ancestors is listed
  local p="$1" i
  for i in 1 2 3 4; do
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)" || return 1
    [ -z "$p" ] || [ "$p" = "1" ] && return 1
    grep -qx "$p" "$2" && return 0
  done
  return 1
}

# Async LLM title: writes $CACHE/llm/<key> once; prints cached text if present.
llm_title() { # key prompt
  local key="$1" prompt="$2" f="$CACHE/llm/$1"
  [ -s "$f" ] && { cat "$f"; return 0; }
  [ "$LLM" = 1 ] || return 1
  if [ -e "$f.lock" ]; then
    # a lock older than 2 min means the background titler died (killed shell, reboot mid-run)
    [ -n "$(find "$f.lock" -mmin +2 2>/dev/null)" ] && rm -f "$f.lock" || return 1
  fi
  : > "$f.lock"
  prompt="${prompt:0:600}"   # pasted walls of text: the first 600 chars are plenty for a title
  ( # background, fire-and-forget; Ollama cold-load can take 10s+
    r="$(curl -s -m 40 localhost:11434/api/generate -d "$(jq -cn --arg m "$LLM_MODEL" --arg p "Give a 3-5 word title for this coding session request. Output only the title, no quotes, no period.

Request: $prompt" '{model:$m,stream:false,options:{num_predict:14,temperature:0.2},prompt:$p}')" \
      | jq -r '.response // empty' 2>/dev/null | head -1 | sed -E 's/^[[:space:]"*#-]+//; s/[[:space:]".]+$//')"
    if [ -n "$r" ] && [ "${#r}" -le 60 ]; then printf '%s' "$r" > "$f.tmp" && mv "$f.tmp" "$f"; fi
    rm -f "$f.lock"
  ) >/dev/null 2>&1 &
  return 1
}

# ------------------------------------------------------------------ first-prompt resolvers
# Each prints the raw first user prompt (or a title) for a session, or nothing.
claude_first_prompt() { # sid cwd
  local sid="$1" cwd="$2" slug f
  slug="$(printf '%s' "$cwd" | sed 's#[/.]#-#g')"
  f="$HOME/.claude/projects/$slug/$sid.jsonl"
  [ -r "$f" ] || f="$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
  [ -r "$f" ] || return 1
  head -c 60000 "$f" | jq -r 'select(.type=="user") | .message.content
      | if type=="string" then . else (map(select(.type=="text")|.text)|join(" ")) end
      | select(test("^\\s*(<|$)") | not) | @json' 2>/dev/null | head -1 | jq -r . 2>/dev/null
}
claude_sid_by_start() { # cwd start_epoch → sid whose jsonl first timestamp is within 20s
  local slug d f ts
  slug="$(printf '%s' "$1" | sed 's#[/.]#-#g')"; d="$HOME/.claude/projects/$slug"
  [ -d "$d" ] || return 1
  for f in $(ls -t "$d"/*.jsonl 2>/dev/null | head -8); do
    ts="$(head -c 4000 "$f" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -n "$ts" ] || continue
    if [ "$(abs_diff "$(epoch_of "$ts")" "$2")" -le 20 ]; then basename "$f" .jsonl; return 0; fi
  done
  return 1
}
codex_first_prompt() { # start_epoch cwd → first real user message of the rollout started then
  local f ts best=""
  for f in $(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -40); do
    ts="$(head -1 "$f" | jq -r 'select(.type=="session_meta") | .payload.timestamp' 2>/dev/null)"
    [ -n "$ts" ] || continue
    if [ "$(abs_diff "$(epoch_of "$ts")" "$1")" -le 20 ]; then best="$f"; break; fi
  done
  [ -n "$best" ] || return 1
  head -c 400000 "$best" | jq -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="user")
      | .payload.content | map(select(.type=="input_text")|.text) | join(" ")
      | select(test("^\\s*(<|$)") | not) | @json' 2>/dev/null | head -1 | jq -r . 2>/dev/null
}
opencode_title() { # start_epoch cwd
  local db="$HOME/.local/share/opencode/opencode.db"
  [ -r "$db" ] && command -v sqlite3 >/dev/null || return 1
  sqlite3 -readonly "$db" "select title from session where directory='$(printf '%s' "$2" | sed "s/'/''/g")' and abs(time_created/1000 - $1) <= 20 order by time_created desc limit 1" 2>/dev/null | head -1
}
grok_first_prompt() { # start_epoch cwd
  local enc f
  enc="$(printf '%s' "$2" | jq -sRr @uri)"
  f="$HOME/.grok/sessions/$enc/prompt_history.jsonl"
  [ -r "$f" ] || return 1
  # first non-bash prompt typed after process start (−5s slack)
  jq -r --argjson s "$1" 'select(.is_bash!=true) | [(.timestamp|sub("\\.[0-9]+Z$";"Z")|fromdate), .prompt] | @tsv' "$f" 2>/dev/null \
    | awk -F'\t' -v s="$1" '$1 >= s-5 {print $2; exit}'
}

# ------------------------------------------------------------------ gather
clients="$(hyprctl clients -j 2>/dev/null || echo '[]')"
names="$( [ -r "$STATE/session-names.json" ] && cat "$STATE/session-names.json" || echo '{}' )"
kmap='{}'
for f in "$STATE"/kitty-sessions/*.json; do
  [ -r "$f" ] || continue
  sid="$(basename "$f" .json)"
  kpid="$(jq -r '.listenOn // ""' "$f" 2>/dev/null | sed -n 's/.*omarchy-kitty-\([0-9]*\)$/\1/p')"
  [ -n "$kpid" ] && kmap="$(jq -c --arg k "$kpid" --arg s "$sid" '. + {($k): $s}' <<<"$kmap")"
done

# Candidate agent processes: pid<TAB>agent
cands="$(mktemp)"; trap 'rm -f "$cands" "$cands.pids"' EXIT
ps -eo pid=,comm=,args= | while read -r pid comm args; do
  agent=""
  case "$comm" in
    claude)   agent=claude ;;
    codex)    agent=codex ;;
    opencode) agent=opencode ;;
    aider)    agent=aider ;;
    node|bun|python*|gemini|grok|copilot)
      case "$args" in
        *"/grok/bin/grok"*|*"/.bin/grok"*|*"/grok/dist/"*)          agent=grok ;;
        *"gemini-cli"*|*"/.bin/gemini"*|*"/gemini/dist/"*)          agent=gemini ;;
        *"/copilot"*"/index.js"*|*"/.bin/copilot"*|*"copilot-cli"*) agent=copilot ;;
        *"aider"*)                                                  agent=aider ;;
      esac ;;
  esac
  [ -n "$agent" ] || continue
  [ "$(filter_args "$args")" = keep ] || continue
  printf '%s\t%s\n' "$pid" "$agent"
done > "$cands"
cut -f1 "$cands" > "$cands.pids"

out='[]'
while IFS=$'\t' read -r pid agent; do
  [ -d /proc/"$pid" ] || continue
  # Skip helpers whose ancestor is already an agent (workers, sub-shells, forks).
  ancestor_in_set "$pid" "$cands.pids" && continue
  argv="$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null)" || continue
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -z "$tty" ] || [ "$tty" = "?" ]; then
    pargs="$(tr '\0' ' ' </proc/"$(awk '{print $4}' /proc/"$pid"/stat 2>/dev/null)"/cmdline 2>/dev/null)"
    case "$pargs" in *bg-pty-host*) ;; *) continue ;; esac   # headless/agent-spawned → skip
  fi
  etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"; etimes="${etimes:-0}"
  start="$(start_epoch "$pid")"
  cwd="$(readlink /proc/"$pid"/cwd 2>/dev/null || echo "")"
  project="$(basename "${cwd:-/}")"
  kpid="$(kitty_ancestor "$pid")"

  # session id
  sid="$(sed -n 's/.*--session-id \([0-9a-f-]\{36\}\).*/\1/p' <<<"$argv")"
  if [ "$agent" = claude ]; then
    [ -z "$sid" ] && [ -n "$kpid" ] && sid="$(jq -r --arg k "$kpid" '.[$k] // ""' <<<"$kmap")"
    [ -z "$sid" ] && sid="$(claude_sid_by_start "$cwd" "$start" || true)"
  fi
  [ -z "$sid" ] && sid="$agent-$pid"

  # window + state
  addr="" ws="" title=""
  if [ -n "$kpid" ]; then
    read -r addr ws title < <(jq -r --argjson p "$kpid" \
      '[.[] | select(.pid == $p)] | first // empty | "\(.address) \(.workspace.id) \(.title)"' <<<"$clients")
  fi
  state="$(state_from_title "$title")"
  [ -z "$addr" ] && attached=false || attached=true

  # ---- crisp name (cached per pid+start once settled)
  ckey="$pid-$start"; cf="$CACHE/names/$ckey"
  name=""; src=""
  [ -s "$cf" ] && IFS=$'\t' read -r src name < "$cf"
  if [ -z "$name" ]; then
    prompt=""
    case "$agent" in
      claude)
        [ "$sid" != "claude-$pid" ] && prompt="$(claude_first_prompt "$sid" "$cwd" || true)"
        if [ -z "$prompt" ] && [ -r "$STATE/current-work-$sid.json" ]; then
          prompt="$(jq -r '.task_title // ""' "$STATE/current-work-$sid.json" 2>/dev/null)"
        fi ;;
      codex)    prompt="$(codex_first_prompt "$start" "$cwd" || true)"
                # Codex desktop cwd slug (Documents/Codex/<date>/<slug>) is already a title
                [ -z "$prompt" ] && case "$cwd" in */Documents/Codex/*) prompt="$(basename "$cwd" | tr '-' ' ')" ;; esac ;;
      opencode) name="$(opencode_title "$start" "$cwd" || true)"; [ -n "$name" ] && src=agent ;;
      grok)     prompt="$(grok_first_prompt "$start" "$cwd" || true)" ;;
    esac
    if [ -z "$name" ] && [ -n "$prompt" ]; then name="$(trim_name "$prompt")"; src=prompt; fi
    if [ -z "$name" ] && [ "$agent" = claude ]; then
      name="$(jq -r --arg s "$sid" '.[$s] // ""' <<<"$names")"; [ -n "$name" ] && src=hook
    fi
    [ -z "$name" ] && { name="$project"; src=dir; }
    # Upgrade to an LLM title when we have a real prompt (async; lands on a later poll).
    if [ -n "$prompt" ] && t="$(llm_title "$ckey" "$prompt")"; then name="$(trim_name "$t")"; src=llm; fi
    # Cache settled names only: llm / agent-provided, or prompt-trim when LLM is disabled.
    if [ "$src" = llm ] || [ "$src" = agent ] || { [ "$src" = prompt ] && [ "$LLM" = 0 ]; }; then
      printf '%s\t%s' "$src" "$name" > "$cf"
    fi
  fi

  out="$(jq -c \
    --argjson pid "$pid" --arg sid "$sid" --arg name "$name" --arg src "$src" --arg cwd "$cwd" \
    --arg project "$project" --arg state "$state" --arg title "$title" \
    --arg kpid "${kpid:-0}" --arg addr "$addr" --arg ws "${ws:-0}" --arg et "$etimes" \
    --arg agent "$agent" --argjson attached "$attached" \
    '. + [{pid:$pid, sid:$sid, name:$name, title_src:$src, cwd:$cwd, project:$project, state:$state,
           agent:$agent, attached:$attached, title:$title, kittyPid:($kpid|tonumber),
           address:$addr, workspace:($ws|tonumber? // 0), etimes:($et|tonumber? // 0)}]' <<<"$out")"
done < "$cands"

jq -c 'sort_by(.etimes)' <<<"$out"
