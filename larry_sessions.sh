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
umask 077
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
  CACHE="$XDG_RUNTIME_DIR/larry.status"
else
  CACHE="${TMPDIR:-/tmp}/larry.status-$(id -u)"   # never a shared predictable /tmp path
fi
NAME_MAX=44
LLM_MODEL="${LARRY_STATUS_LLM_MODEL:-gemma2:latest}"
LLM=1; [ "${LARRY_STATUS_NO_LLM:-0}" = 1 ] && LLM=0
mkdir -p "$CACHE/names" "$CACHE/llm" 2>/dev/null
# refuse to use a cache we don't own or that is a symlink (another user could pre-create /tmp paths)
for d in "$CACHE" "$CACHE/names" "$CACHE/llm"; do
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo '[]'; exit 0; }
done
chmod -R go-rwx "$CACHE" 2>/dev/null   # entries written before the umask hardening
# prune stale entries once a day (long uptimes, many sessions)
if [ -z "$(find "$CACHE/.pruned" -mmin -1440 2>/dev/null)" ]; then
  find "$CACHE/names" "$CACHE/llm" -type f -mtime +7 -delete 2>/dev/null; : > "$CACHE/.pruned"
fi
# one field, one line: tabs/newlines in untrusted text must never reach the TSV framing
san() { printf '%s' "$1" | tr '\t\n\r' '   '; }

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
filter_argv() { # argv... → keep | skip   (argv[1] = subcommand; flags judged as whole tokens)
  local sub="${2:-}" a
  case "$sub" in
    daemon|exec|mcp|mcp-server|serve|run|login|logout|update|doctor|config|install|bg-pty-host|bg-spare|--version|-v|--help|-h|-p|--print) echo skip; return ;;
  esac
  # exact-token flags anywhere in argv (a prompt is one argv token, so its words can't match)
  for a in "${@:2}"; do
    case "$a" in -p|--print|--bg-pty-host|--bg-spare|bg-pty-host|mcp-server) echo skip; return ;; esac
  done
  echo keep
}
filter_args() { local -a a; read -ra a <<<"$1"; filter_argv "${a[@]}"; }   # test hook (space-split)
case "${1:-}" in
  --state-of) state_from_title "${2:-}"; exit 0 ;;
  --filter-of) filter_args "${2:-}"; exit 0 ;;
  --trim)     trim_name "${2:-}"; echo; exit 0 ;;
  --no-llm)   LLM=0 ;;
esac
command -v jq >/dev/null 2>&1 || { echo '[]'; exit 0; }

epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }
abs_diff() { local d=$(( $1 - $2 )); echo "${d#-}"; }
BTIME="$(awk '/^btime/ {print $2}' /proc/stat)"; CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"; NOW="$(printf '%(%s)T' -1)"
start_epoch() { # pid → epoch seconds, from /proc (no ps/date spawn)
  local st; st="$(awk '{print $22}' /proc/"$1"/stat 2>/dev/null)" || { echo 0; return; }
  echo $(( BTIME + st / CLK_TCK ))
}

kitty_ancestor() { # pid → nearest ancestor whose comm is kitty (or empty)
  local p="$1" c
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$p" != "0" ]; do
    c="$(cat /proc/"$p"/comm 2>/dev/null)" || return 0
    if [ "$c" = "kitty" ]; then echo "$p"; return 0; fi
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)"
  done
}
ancestor_in_set() { # pid setfile → 0 if any of up to 8 ancestors is listed
  local p="$1" i
  for i in 1 2 3 4 5 6 7 8; do
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)" || return 1
    [ -z "$p" ] || [ "$p" = "1" ] && return 1
    grep -qx "$p" "$2" && return 0
  done
  return 1
}

# Async LLM title: writes $CACHE/llm/<key> once; prints cached text if present.
llm_title() { # _unused prompt  (cache key = hash of the prompt, so forks/resumes share a title)
  local prompt="$2" key f
  key="$(printf '%s' "$prompt" | md5sum | cut -c1-16)"; f="$CACHE/llm/$key"
  [ -s "$f" ] && { cat "$f"; return 0; }
  [ "$LLM" = 1 ] || return 1
  # mkdir is atomic: two collector instances (Omarchy instantiates widgets twice) can't both win.
  if ! mkdir "$f.lock" 2>/dev/null; then
    # a lock older than 2 min means the background titler died (killed shell, reboot mid-run)
    [ -n "$(find "$f.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$f.lock" 2>/dev/null && mkdir "$f.lock" 2>/dev/null || return 1
  fi
  prompt="${prompt:0:600}"   # pasted walls of text: the first 600 chars are plenty for a title
  ( # background, fire-and-forget; Ollama cold-load can take 10s+
    r="$(curl -s -m 40 localhost:11434/api/generate -d "$(jq -cn --arg m "$LLM_MODEL" --arg p "Give a 3-5 word title for this coding session request. Output only the title, no quotes, no period.

Request: $prompt" '{model:$m,stream:false,options:{num_predict:14,temperature:0.2},prompt:$p}')" \
      | jq -r '.response // empty' 2>/dev/null | head -1 | sed -E 's/^[[:space:]"*#-]+//; s/[[:space:]".]+$//')"
    if [ -n "$r" ] && [ "${#r}" -le 60 ]; then
      t="$(mktemp "$CACHE/llm/.tmp.XXXXXX")" && printf '%s' "$(san "$r")" > "$t" && mv -f "$t" "$f"
    fi
    rmdir "$f.lock" 2>/dev/null
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
claude_sid_by_start() { # cwd start_epoch → sid whose jsonl first timestamp is CLOSEST (≤20s)
  local slug d f ts diff best="" bestd=999
  slug="$(printf '%s' "$1" | sed 's#[/.]#-#g')"; d="$HOME/.claude/projects/$slug"
  [ -d "$d" ] || return 1
  while IFS= read -r f; do
    ts="$(head -c 4000 "$f" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -n "$ts" ] || continue
    diff="$(abs_diff "$(epoch_of "$ts")" "$2")"
    [ "$diff" -le 20 ] && [ "$diff" -lt "$bestd" ] && { best="$f"; bestd="$diff"; }
  done < <(ls -t "$d"/*.jsonl 2>/dev/null | head -8)
  [ -n "$best" ] && basename "$best" .jsonl
}
codex_first_prompt() { # start_epoch cwd → first real user message of the rollout started then
  # closest session_meta timestamp within 20s; a cwd match beats a non-match at any distance
  local f ts mcwd diff best="" bestd=999 bestcwd=0
  while IFS= read -r f; do
    read -r ts mcwd < <(head -1 "$f" | jq -r 'select(.type=="session_meta") | "\(.payload.timestamp) \(.payload.cwd // "")"' 2>/dev/null)
    [ -n "${ts:-}" ] || continue
    diff="$(abs_diff "$(epoch_of "$ts")" "$1")"; [ "$diff" -le 20 ] || continue
    if [ "$mcwd" = "$2" ]; then
      { [ "$bestcwd" = 0 ] || [ "$diff" -lt "$bestd" ]; } && { best="$f"; bestd="$diff"; bestcwd=1; }
    elif [ "$bestcwd" = 0 ] && [ "$diff" -lt "$bestd" ]; then best="$f"; bestd="$diff"; fi
  done < <(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -40)
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
cands="$(mktemp "$CACHE/.cands.XXXXXX")" || { echo '[]'; exit 0; }
trap 'rm -f "$cands" "$cands.pids" "${rows:-}"' EXIT
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
  printf '%s\t%s\n' "$pid" "$agent"
done > "$cands"
cut -f1 "$cands" > "$cands.pids"

rows="$(mktemp "$CACHE/.rows.XXXXXX")" || { echo '[]'; exit 0; }
while IFS=$'\t' read -r pid agent; do
  [ -d /proc/"$pid" ] || continue
  st0="$(awk '{print $22}' /proc/"$pid"/stat 2>/dev/null)"; [ -n "$st0" ] || continue
  # Skip helpers whose ancestor is already an agent (workers, sub-shells, forks).
  ancestor_in_set "$pid" "$cands.pids" && continue
  # real argv boundaries (NUL-delimited) — a prompt word can never look like a subcommand
  mapfile -d '' -t argvA < /proc/"$pid"/cmdline 2>/dev/null || continue
  [ "${#argvA[@]}" -gt 0 ] || continue
  [ "$(filter_argv "${argvA[@]}")" = keep ] || continue
  argv="${argvA[*]}"
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -z "$tty" ] || [ "$tty" = "?" ]; then
    pargs="$(tr '\0' ' ' </proc/"$(awk '{print $4}' /proc/"$pid"/stat 2>/dev/null)"/cmdline 2>/dev/null)"
    case "$pargs" in *bg-pty-host*) ;; *) continue ;; esac   # headless/agent-spawned → skip
  fi
  start="$(start_epoch "$pid")"; [ "$start" -gt 0 ] || continue
  etimes=$(( NOW - start )); [ "$etimes" -lt 0 ] && etimes=0
  cwd="$(readlink /proc/"$pid"/cwd 2>/dev/null || echo "")"
  project="$(basename "${cwd:-/}")"

  # ---- static facts per process (sid, kitty pid, prompt, name) — cached per pid+start.
  # Only title/state/window/etimes are re-read every poll.
  ckey="$pid-$start"; cf="$CACHE/names/$ckey"
  sid="" name="" src="" prompt=""
  cache_ok=0
  if [ -s "$cf" ] && [ ! -L "$cf" ] && IFS=$'\t' read -r src name sid kpid prompt < "$cf" \
     && [[ "$src" =~ ^(llm|prompt|agent|hook|dir)$ ]] && [ -n "$name" ] && [ -n "$sid" ] && [[ "$kpid" =~ ^([0-9]+|-)$ ]]; then
    cache_ok=1; [ "$kpid" = "-" ] && kpid=""
  else
    rm -f "$cf"; src="" name="" sid="" kpid="" prompt=""
  fi
  if [ "$cache_ok" = 0 ]; then
    kpid="$(kitty_ancestor "$pid")"
    sid=""; for ((i=0; i<${#argvA[@]}-1; i++)); do
      [ "${argvA[$i]}" = "--session-id" ] && [[ "${argvA[$((i+1))]}" =~ ^[0-9a-f-]{36}$ ]] && { sid="${argvA[$((i+1))]}"; break; }
    done
    if [ "$agent" = claude ]; then
      [ -z "$sid" ] && [ -n "$kpid" ] && sid="$(jq -r --arg k "$kpid" '.[$k] // ""' <<<"$kmap")"
      [ -z "$sid" ] && sid="$(claude_sid_by_start "$cwd" "$start" || true)"
    fi
    [ -z "$sid" ] && sid="$agent-$pid"
    case "$agent" in
      claude)
        [ "$sid" != "claude-$pid" ] && prompt="$(claude_first_prompt "$sid" "$cwd" || true)"
        if [ -z "$prompt" ] && [ -r "$STATE/current-work-$sid.json" ]; then
          prompt="$(jq -r '.task_title // ""' "$STATE/current-work-$sid.json" 2>/dev/null)"
        fi ;;
      codex)    prompt="$(codex_first_prompt "$start" "$cwd" || true)"
                [ -z "$prompt" ] && case "$cwd" in */Documents/Codex/*) prompt="$(basename "$cwd" | tr '-' ' ')" ;; esac ;;
      opencode) name="$(opencode_title "$start" "$cwd" || true)"; [ -n "$name" ] && src=agent ;;
      grok)     prompt="$(grok_first_prompt "$start" "$cwd" || true)" ;;
    esac
    prompt="$(san "$prompt")"; prompt="${prompt:0:600}"
    if [ -z "$name" ] && [ -n "$prompt" ]; then name="$(trim_name "$prompt")"; src=prompt; fi
    if [ -z "$name" ] && [ "$agent" = claude ]; then
      name="$(jq -r --arg s "$sid" '.[$s] // ""' <<<"$names")"; [ -n "$name" ] && src=hook
    fi
    [ -z "$name" ] && { name="$project"; src=dir; }
    # sessions younger than 30s may not have written their transcript yet — don't freeze a weak name
    if [ "$src" = llm ] || [ "$src" = agent ] || [ -n "$prompt" ] || [ "$etimes" -gt 30 ]; then
      printf '%s\t%s\t%s\t%s\t%s' "$src" "$(san "$name")" "$(san "$sid")" "${kpid:--}" "$prompt" > "$cf"
    fi
  fi
  # Upgrade to an LLM title once the async titler has produced one.
  if [ "$src" != llm ] && [ -n "$prompt" ] && t="$(llm_title "$ckey" "$prompt")"; then
    name="$(trim_name "$t")"; src=llm
    printf '%s\t%s\t%s\t%s\t%s' "$src" "$(san "$name")" "$(san "$sid")" "${kpid:--}" "$prompt" > "$cf"
  fi

  # window + state (dynamic)
  addr="" ws="" title=""
  if [ -n "$kpid" ]; then
    read -r addr ws title < <(jq -r --argjson p "$kpid" \
      '[.[] | select(.pid == $p)] | first // empty | "\(.address) \(.workspace.id) \(.title)"' <<<"$clients")
  fi
  state="$(state_from_title "$title")"
  [ -z "$addr" ] && attached=false || attached=true

  # PID reuse guard: the process we described must be the one still running
  [ "$(awk '{print $22}' /proc/"$pid"/stat 2>/dev/null)" = "$st0" ] || continue
  [[ "$addr" =~ ^(0x[0-9a-fA-F]+)?$ ]] || addr=""
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pid" "$(san "$sid")" "$(san "$name")" "$src" "$(san "$cwd")" "$(san "$project")" "$state" "$agent" "$attached" \
    "$(san "$title")" "${kpid:-0}" "$addr" "${ws:-0}" "$etimes" >> "$rows"
done < "$cands"

jq -Rsc 'split("\n") | map(select(length>0) | split("\t")) | map({
    pid:(.[0]|tonumber), sid:.[1], name:.[2], title_src:.[3], cwd:.[4], project:.[5], state:.[6],
    agent:.[7], attached:(.[8]=="true"), title:.[9], kittyPid:(.[10]|tonumber? // 0),
    address:.[11], workspace:(.[12]|tonumber? // 0), etimes:(.[13]|tonumber? // 0)})
  | sort_by(.etimes)' "$rows"
