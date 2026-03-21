#!/bin/bash
set -u -o pipefail
input=$(cat)

# ── Colors (true color, ANSI-C quoting for real ESC bytes) ──
RED=$'\e[38;2;255;85;85m'
YEL=$'\e[38;2;230;200;0m'
GRN=$'\e[38;2;0;175;80m'
CYN=$'\e[38;2;86;182;194m'
BLU=$'\e[38;2;0;153;255m'
# VAL: value color (orange for contrast on light themes)
VAL=$'\e[38;2;230;140;50m'
DIM=$'\e[2m'
RST=$'\e[0m'
# LBL: label color (dark for light themes)
LBL=$'\e[38;2;80;80;80m'
# DIMCIR: empty bar circles (visible on light themes)
DIMCIR=$'\e[38;2;190;195;190m'

# ── Configuration (env vars) ──
SHOW_GIT="${CC_SHOW_GIT:-1}"
SHOW_EFFORT="${CC_SHOW_EFFORT:-1}"
SHOW_USAGE="${CC_SHOW_USAGE:-1}"
SHOW_SPEED="${CC_SHOW_SPEED:-0}"
SHOW_TOOLS="${CC_SHOW_TOOLS:-0}"
SHOW_AGENTS="${CC_SHOW_AGENTS:-0}"
SHOW_TODOS="${CC_SHOW_TODOS:-0}"
SHOW_SESSION="${CC_SHOW_SESSION:-0}"

W=72

# ── Cache directory (SEC-002: per-user, private) ──
CACHE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cc-statusline"
umask 077
mkdir -p "$CACHE_DIR"

# ── Helpers ──
# SEC-001: Validate numeric values before arithmetic to prevent injection
safe_int() { [[ $1 =~ ^-?[0-9]+$ ]] && printf '%s' "$1" || printf '0'; }
fmt_k() {
  local v=$1
  if [ "$v" -ge 1000000 ] 2>/dev/null; then
    printf "%.1fM" "$(echo "$v / 1000000" | bc -l)"
  elif [ "$v" -ge 1000 ] 2>/dev/null; then
    echo "$((v / 1000))k"
  else
    echo "$v"
  fi
}

jval() { echo "$input" | jq -r "$1 // $2"; }

vis_len() {
  local stripped
  stripped=$(echo -ne "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
  echo "${#stripped}"
}

row() {
  printf "%b\n" "$1"
}

HLINE="${DIM}$(printf "%${W}s" '' | sed 's/ /─/g')${RST}"

# ── Context Window (SEC-001: all values validated before arithmetic) ──
PCT=$(safe_int "$(jval '.context_window.used_percentage' '0' | cut -d. -f1)")
CTX_SIZE=$(safe_int "$(jval '.context_window.context_window_size' '1000000')")
CUR_IN=$(safe_int "$(jval '.context_window.current_usage.input_tokens' '0')")
CUR_OUT=$(safe_int "$(jval '.context_window.current_usage.output_tokens' '0')")
CACHE_WR=$(safe_int "$(jval '.context_window.current_usage.cache_creation_input_tokens' '0')")
CACHE_RD=$(safe_int "$(jval '.context_window.current_usage.cache_read_input_tokens' '0')")
CTX_USED=$((CUR_IN + CUR_OUT + CACHE_WR + CACHE_RD))

if [ "$PCT" -ge 80 ]; then CTX_CLR=$RED
elif [ "$PCT" -ge 50 ]; then CTX_CLR=$YEL
else CTX_CLR=$GRN; fi

FILLED=$((PCT * 30 / 100))
BAR="${CTX_CLR}$(printf '%*s' "$FILLED" '' | sed 's/ /█/g')${DIMCIR}$(printf '%*s' "$((30 - FILLED))" '' | sed 's/ /░/g')${RST}"

# ── Session Info ──
TOTAL_COST=$(jval '.cost.total_cost_usd' '0')
DUR_MS=$(safe_int "$(jval '.cost.total_duration_ms' '0')")
TRANSCRIPT=$(jval '.transcript_path' '""')
SESSION_ID=$(jval '.session_id' '""')
MODEL_NAME=$(jval '.model.display_name' '"?"')
VERSION=$(jval '.version' '"?"')

COST_FMT=$(printf '$%.2f' "$TOTAL_COST")
DAYS=$((DUR_MS / 86400000))
HOURS=$(( (DUR_MS % 86400000) / 3600000 ))
MINS=$(( (DUR_MS % 3600000) / 60000 ))
SECS=$(( (DUR_MS % 60000) / 1000 ))
TIME_FMT=""
[ "$DAYS" -gt 0 ] && TIME_FMT="${DAYS}d "
[ "$HOURS" -gt 0 ] && TIME_FMT="${TIME_FMT}${HOURS}h "
[ "$MINS" -gt 0 ] && TIME_FMT="${TIME_FMT}${MINS}m "
TIME_FMT="${TIME_FMT}${SECS}s"

CWD=$(jval '.cwd' '"?"')
PROJECT_DIR=$(jval '.workspace.project_dir' '"?"')
PROJECT_NAME=$(basename "$PROJECT_DIR")
CWD_SHORT=$(echo "$CWD" | sed "s|$HOME|~|")

# ── Git Info ──
GIT_INFO=""
if [ "$SHOW_GIT" != "0" ]; then
  GIT_BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$GIT_BRANCH" ]; then
    GIT_DIRTY=""
    if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
      GIT_DIRTY="${RED}*${RST}"
    fi
    GIT_INFO="  ${GRN}${GIT_BRANCH}${RST}${GIT_DIRTY}"
  fi
fi

# ── Effort Level ──
EFFORT_INFO=""
if [ "$SHOW_EFFORT" != "0" ]; then
  EFFORT=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null)
  case "$EFFORT" in
    high)   EFFORT_INFO="  ${LBL}● ${EFFORT}${RST}" ;;
    medium) EFFORT_INFO="  ${LBL}◑ ${EFFORT}${RST}" ;;
    low)    EFFORT_INFO="  ${LBL}◔ ${EFFORT}${RST}" ;;
    *)      EFFORT_INFO="  ${LBL}◑ ${EFFORT}${RST}" ;;
  esac
fi

# ── Token Speed ──
# Note: CUR_OUT is context-window-scoped output tokens, not cumulative session total.
# Speed readings reset after context compaction. This is a known limitation.
SPEED_INFO=""
# SEC-003: Hash session ID to prevent path traversal
SESSION_KEY=$(printf '%s' "$SESSION_ID" | sha256sum | cut -c1-16)
if [ "$SHOW_SPEED" != "0" ]; then
  SPEED_CACHE="${CACHE_DIR}/cc-speed-${SESSION_KEY}.dat"
  NOW_MS=$(($(date +%s) * 1000))
  if [ -f "$SPEED_CACHE" ]; then
    PREV_OUT=$(safe_int "$(sed -n '1p' "$SPEED_CACHE")")
    PREV_MS=$(safe_int "$(sed -n '2p' "$SPEED_CACHE")")
    DELTA_T=$((NOW_MS - PREV_MS))
    DELTA_O=$((CUR_OUT - PREV_OUT))
    if [ "$DELTA_O" -lt 0 ]; then
      : # Context compaction — skip, cache will be overwritten below
    elif [ "$DELTA_T" -gt 0 ] && [ "$DELTA_O" -gt 0 ]; then
      SPEED=$(echo "scale=1; $DELTA_O * 1000 / $DELTA_T" | bc -l)
      SPEED_INFO="  ${VAL}${SPEED} tok/s${RST}"
    fi
  fi
  printf '%s\n%s\n' "$CUR_OUT" "$NOW_MS" > "$SPEED_CACHE"
fi

# ── Cost Breakdown (transcript parse with 5s cache) ──
CACHE_FILE="${CACHE_DIR}/cc-cost-${SESSION_KEY}.dat"
PARSE=1
if [ -f "$CACHE_FILE" ]; then
  CACHE_MOD=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  [ $((NOW - CACHE_MOD)) -lt 5 ] && PARSE=0
fi

if [ "$PARSE" -eq 1 ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  COST_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" TOTAL_COST_USD="$TOTAL_COST" \
    SHOW_TOOLS="$SHOW_TOOLS" SHOW_AGENTS="$SHOW_AGENTS" \
    SHOW_TODOS="$SHOW_TODOS" SHOW_SESSION="$SHOW_SESSION" python3 << 'PYEOF'
import json, sys, os
from collections import defaultdict

transcript = os.environ.get("TRANSCRIPT_PATH", "")
total_cost = float(os.environ.get("TOTAL_COST_USD", "0"))
show_tools = os.environ.get("SHOW_TOOLS", "0") != "0"
show_agents = os.environ.get("SHOW_AGENTS", "0") != "0"
show_todos = os.environ.get("SHOW_TODOS", "0") != "0"
show_session = os.environ.get("SHOW_SESSION", "0") != "0"

# 8 output lines always emitted
out = ["0.00", "0.00", "0.00", "0.00", "", "", "", ""]

if not transcript or not os.path.isfile(transcript):
    print("\n".join(out))
    sys.exit(0)

PRICING = {
    "claude-opus-4":   {"in": 5,    "out": 25, "c5m": 6.25, "c1h": 10,  "crd": 0.50},
    "claude-sonnet-4": {"in": 3,    "out": 15, "c5m": 3.75, "c1h": 6,   "crd": 0.30},
    "claude-sonnet-3": {"in": 3,    "out": 15, "c5m": 3.75, "c1h": 6,   "crd": 0.30},
    "claude-haiku-4":  {"in": 1,    "out": 5,  "c5m": 1.25, "c1h": 2,   "crd": 0.10},
    "claude-haiku-3":  {"in": 0.80, "out": 4,  "c5m": 1,    "c1h": 1.6, "crd": 0.08},
}

def get_pricing(model):
    for prefix, prices in PRICING.items():
        if model and model.startswith(prefix):
            return prices
    return PRICING["claude-opus-4"]

by_id = {}
tools = {}
agents = {}
todos = []
session_name = ""
task_id_map = {}

with open(transcript) as f:
    for line in f:
        try:
            e = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue

        # Session name
        if show_session:
            if e.get("type") == "custom-title" and isinstance(e.get("customTitle"), str):
                session_name = e["customTitle"]
            elif isinstance(e.get("slug"), str):
                if not session_name:
                    session_name = e["slug"]

        msg = e.get("message", {})
        if msg.get("usage") and msg.get("id"):
            by_id[msg["id"]] = msg

        # Reset tools on each new assistant message (scope to last turn)
        if show_tools and e.get("type") == "assistant" and msg.get("role") == "assistant":
            tools.clear()

        content = msg.get("content", [])
        if not isinstance(content, list):
            continue

        ts = e.get("timestamp", "")

        for block in content:
            btype = block.get("type")
            bid = block.get("id", "")
            bname = block.get("name", "")
            inp = block.get("input", {}) or {}

            if btype == "tool_use" and bid and bname:
                if bname == "Task" and show_agents:
                    agents[bid] = {
                        "type": inp.get("subagent_type", "agent"),
                        "model": inp.get("model", ""),
                        "desc": (inp.get("description", "") or "")[:40],
                        "ts": ts, "status": "running"
                    }
                elif bname == "TodoWrite" and show_todos:
                    raw = inp.get("todos", [])
                    if isinstance(raw, list):
                        todos.clear()
                        task_id_map.clear()
                        for t in raw:
                            if isinstance(t, dict):
                                todos.append({"content": t.get("content", ""), "status": t.get("status", "pending")})
                elif bname == "TaskCreate" and show_todos:
                    subj = inp.get("subject", "") or inp.get("description", "") or "Task"
                    status = inp.get("status", "pending")
                    if status in ("not_started",): status = "pending"
                    if status in ("running",): status = "in_progress"
                    if status in ("complete", "done"): status = "completed"
                    todos.append({"content": subj, "status": status})
                    tid = str(inp.get("taskId", bid))
                    task_id_map[tid] = len(todos) - 1
                elif bname == "TaskUpdate" and show_todos:
                    tid = str(inp.get("taskId", ""))
                    idx = task_id_map.get(tid)
                    if idx is None and tid.isdigit():
                        ni = int(tid) - 1
                        if 0 <= ni < len(todos): idx = ni
                    if idx is not None and 0 <= idx < len(todos):
                        st = inp.get("status")
                        if st in ("not_started",): st = "pending"
                        if st in ("running",): st = "in_progress"
                        if st in ("complete", "done"): st = "completed"
                        if st in ("pending", "in_progress", "completed"):
                            todos[idx]["status"] = st
                        subj = inp.get("subject", "") or inp.get("description", "")
                        if subj: todos[idx]["content"] = subj
                elif show_tools and bname not in ("Task", "TodoWrite", "TaskCreate", "TaskUpdate"):
                    target = ""
                    if bname in ("Read", "Write", "Edit"):
                        target = inp.get("file_path", inp.get("path", ""))
                        if target:
                            target = target.rsplit("/", 1)[-1]
                    elif bname in ("Glob", "Grep"):
                        target = inp.get("pattern", "")
                    elif bname == "Bash":
                        cmd = inp.get("command", "")
                        target = cmd[:25] + ("..." if len(cmd) > 25 else "")
                    tools[bid] = {"name": bname, "target": target, "status": "running"}

            elif btype == "tool_result" and block.get("tool_use_id"):
                tuid = block["tool_use_id"]
                if tuid in tools:
                    tools[tuid]["status"] = "error" if block.get("is_error") else "done"
                if tuid in agents:
                    agents[tuid]["status"] = "done"

# Cost calculation
c_cache = c_write = c_out = 0.0
if total_cost > 0:
    for msg in by_id.values():
        u = msg["usage"]
        p = get_pricing(msg.get("model", ""))
        c_cache += u.get("cache_read_input_tokens", 0) * p["crd"] / 1_000_000
        c = u.get("cache_creation", {})
        c_write += c.get("ephemeral_5m_input_tokens", 0) * p["c5m"] / 1_000_000
        c_write += c.get("ephemeral_1h_input_tokens", 0) * p["c1h"] / 1_000_000
        c_write += u.get("input_tokens", 0) * p["in"] / 1_000_000
        c_out   += u.get("output_tokens", 0) * p["out"] / 1_000_000
api_total = c_cache + c_write + c_out
out[0] = f"{c_cache:.2f}"
out[1] = f"{c_write:.2f}"
out[2] = f"{c_out:.2f}"
out[3] = f"{api_total:.2f}"

# Tools line
if show_tools:
    running = [t for t in tools.values() if t["status"] == "running"]
    done = [t for t in tools.values() if t["status"] == "done"]
    parts = []
    for t in running[-3:]:
        label = f"\u25d0 {t['name']}"
        if t["target"]: label += f": {t['target']}"
        parts.append(label)
    counts = defaultdict(int)
    for t in done[-20:]:
        counts[t["name"]] += 1
    for name, cnt in list(counts.items())[-3:]:
        parts.append(f"\u2713 {name} \u00d7{cnt}")
    out[4] = "  \u2502  ".join(parts) if parts else ""

# Agents line
if show_agents:
    running_agents = [a for a in agents.values() if a["status"] == "running"]
    parts = []
    for a in running_agents[-3:]:
        label = f"\u25d0 {a['type']}"
        if a["model"]: label += f" [{a['model']}]"
        if a["desc"]: label += f": {a['desc']}"
        parts.append(label)
    out[5] = "  \u2502  ".join(parts) if parts else ""

# Todos line
if show_todos and todos:
    completed = sum(1 for t in todos if t["status"] == "completed")
    total = len(todos)
    current = next((t for t in todos if t["status"] == "in_progress"), None)
    if not current:
        current = next((t for t in todos if t["status"] == "pending"), None)
    if current:
        name = current["content"][:35]
        out[6] = f"\u25b8 {name} ({completed}/{total})"

# Session name
if show_session and session_name:
    out[7] = session_name

print("\n".join(out))
PYEOF
  )

  if [ -n "$COST_DATA" ]; then
    R_CACHE=$(echo "$COST_DATA" | sed -n '1p')
    R_WRITE=$(echo "$COST_DATA" | sed -n '2p')
    R_OUT=$(echo "$COST_DATA" | sed -n '3p')
    R_API=$(echo "$COST_DATA" | sed -n '4p')
    R_TOOLS=$(echo "$COST_DATA" | sed -n '5p')
    R_AGENTS=$(echo "$COST_DATA" | sed -n '6p')
    R_TODOS=$(echo "$COST_DATA" | sed -n '7p')
    R_SESSION=$(echo "$COST_DATA" | sed -n '8p')
    printf '%s\n' "$R_CACHE" "$R_WRITE" "$R_OUT" "$R_API" "$R_TOOLS" "$R_AGENTS" "$R_TODOS" "$R_SESSION" > "$CACHE_FILE"
  fi
else
  if [ -f "$CACHE_FILE" ]; then
    R_CACHE=$(sed -n '1p' "$CACHE_FILE")
    R_WRITE=$(sed -n '2p' "$CACHE_FILE")
    R_OUT=$(sed -n '3p' "$CACHE_FILE")
    R_API=$(sed -n '4p' "$CACHE_FILE")
    R_TOOLS=$(sed -n '5p' "$CACHE_FILE")
    R_AGENTS=$(sed -n '6p' "$CACHE_FILE")
    R_TODOS=$(sed -n '7p' "$CACHE_FILE")
    R_SESSION=$(sed -n '8p' "$CACHE_FILE")
  fi
fi

# Defaults
: "${R_CACHE:=0.00}" "${R_WRITE:=0.00}" "${R_OUT:=0.00}" "${R_API:=0.00}"
: "${R_TOOLS:=}" "${R_AGENTS:=}" "${R_TODOS:=}" "${R_SESSION:=}"

API_FMT=$(printf '$%.2f' "$R_API")

# ── Usage / Rate Limits ──
USAGE_LINE=""
if [ "$SHOW_USAGE" != "0" ]; then

  get_oauth_token() {
    local token=""
    # 1. Credentials file
    local creds="$HOME/.claude/.credentials.json"
    if [ -f "$creds" ]; then
      token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
      if [ -n "$token" ] && [ "$token" != "null" ]; then echo "$token"; return 0; fi
    fi
    # 2. Linux keychain
    if command -v secret-tool &>/dev/null; then
      local blob
      local timeout_bin
      timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
      if [ -n "$timeout_bin" ]; then
        blob=$("$timeout_bin" 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
      else
        blob=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
      fi
      if [ -n "$blob" ]; then
        token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then echo "$token"; return 0; fi
      fi
    fi
    # 3. macOS keychain
    if command -v security &>/dev/null; then
      local blob
      blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
      if [ -n "$blob" ]; then
        token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then echo "$token"; return 0; fi
      fi
    fi
    echo ""
  }

  build_usage_bar() {
    local pct=$1 width=10
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local clr
    if [ "$pct" -ge 90 ]; then clr=$RED
    elif [ "$pct" -ge 50 ]; then clr=$YEL
    else clr=$GRN; fi
    local f=$(printf '%*s' "$filled" '' | sed 's/ /█/g')
    local e=$(printf '%*s' "$empty" '' | sed 's/ /░/g')
    echo -ne "${clr}${f}${DIMCIR}${e}${RST}"
  }

  format_reset_time() {
    local iso="$1" style="$2"
    [ -z "$iso" ] || [ "$iso" = "null" ] && return
    local epoch
    epoch=$(date -d "$iso" +%s 2>/dev/null)
    if [ -z "$epoch" ]; then
      local stripped="${iso%%.*}"; stripped="${stripped%%Z}"
      epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi
    [ -z "$epoch" ] && return
    case "$style" in
      time)
        date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //' || \
        date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]'
        ;;
      datetime)
        date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/^ //' | tr '[:upper:]' '[:lower:]' || \
        date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]'
        ;;
    esac
  }

  # Fetch usage with caching (60s success, 15s failure)
  USAGE_CACHE="${CACHE_DIR}/cc-usage-cache.json"
  USAGE_DATA=""
  NEEDS_FETCH=true

  if [ -f "$USAGE_CACHE" ]; then
    CACHE_MOD_U=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0)
    NOW_U=$(date +%s)
    CACHE_AGE=$((NOW_U - CACHE_MOD_U))
    if jq -e '.five_hour' "$USAGE_CACHE" &>/dev/null; then
      [ "$CACHE_AGE" -lt 60 ] && NEEDS_FETCH=false
    else
      [ "$CACHE_AGE" -lt 300 ] && NEEDS_FETCH=false
    fi
    USAGE_DATA=$(cat "$USAGE_CACHE" 2>/dev/null)
  fi

  if $NEEDS_FETCH; then
    TOKEN=$(get_oauth_token)
    if [ -n "$TOKEN" ]; then
      RESP=$(curl -s --max-time 5 \
        -H "Authorization: Bearer $TOKEN" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
      if [ -n "$RESP" ] && echo "$RESP" | jq -e '.five_hour' &>/dev/null; then
        USAGE_DATA="$RESP"
        echo "$RESP" > "$USAGE_CACHE"
      else
        echo '{"error":true}' > "$USAGE_CACHE"
      fi
    fi
    [ -z "$USAGE_DATA" ] && [ -f "$USAGE_CACHE" ] && USAGE_DATA=$(cat "$USAGE_CACHE" 2>/dev/null)
  fi

  # Build usage panel content
  if [ -n "$USAGE_DATA" ] && echo "$USAGE_DATA" | jq -e '.five_hour' &>/dev/null; then
    FIVE_PCT=$(safe_int "$(echo "$USAGE_DATA" | jq -r '.five_hour.utilization // 0' | cut -d. -f1)")
    FIVE_RESET_ISO=$(echo "$USAGE_DATA" | jq -r '.five_hour.resets_at // empty')
    FIVE_RESET=$(format_reset_time "$FIVE_RESET_ISO" "time")
    FIVE_BAR=$(build_usage_bar "$FIVE_PCT")

    SEVEN_PCT=$(safe_int "$(echo "$USAGE_DATA" | jq -r '.seven_day.utilization // 0' | cut -d. -f1)")
    SEVEN_RESET_ISO=$(echo "$USAGE_DATA" | jq -r '.seven_day.resets_at // empty')
    SEVEN_RESET=$(format_reset_time "$SEVEN_RESET_ISO" "datetime")
    SEVEN_BAR=$(build_usage_bar "$SEVEN_PCT")

    FIVE_CLR=$GRN; [ "$FIVE_PCT" -ge 50 ] && FIVE_CLR=$YEL; [ "$FIVE_PCT" -ge 90 ] && FIVE_CLR=$RED
    SEVEN_CLR=$GRN; [ "$SEVEN_PCT" -ge 50 ] && SEVEN_CLR=$YEL; [ "$SEVEN_PCT" -ge 90 ] && SEVEN_CLR=$RED

    USAGE_LINE="  ${LBL}5-Hour${RST} ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${RST}"
    [ -n "$FIVE_RESET" ] && USAGE_LINE+=" ${LBL}⟳${RST} ${VAL}${FIVE_RESET}${RST}"
    USAGE_LINE+="   ${LBL}Weekly${RST} ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${RST}"
    [ -n "$SEVEN_RESET" ] && USAGE_LINE+=" ${LBL}⟳${RST} ${VAL}${SEVEN_RESET}${RST}"
  fi

fi

# ── Output ──
SESSION_DISPLAY=""
if [ "$SHOW_SESSION" != "0" ] && [ -n "$R_SESSION" ]; then
  SESSION_DISPLAY="  ${LBL}·${RST} ${VAL}${R_SESSION}${RST}"
fi
printf "%b\n" "$HLINE"
row "  ${BLU}${MODEL_NAME}${RST}  ${VAL}${CWD_SHORT}${RST}  ${GIT_INFO}${EFFORT_INFO}${SESSION_DISPLAY}"
row "  ${BAR}  ${CTX_CLR}${PCT}%${RST}  ${VAL}$(fmt_k "$CTX_USED")/$(fmt_k "$CTX_SIZE")${RST}"
row "  ${LBL}Duration${RST} ${VAL}${TIME_FMT}${RST}  ${LBL}CC${RST} ${VAL}${VERSION}${RST}${SPEED_INFO}"
row "  ${LBL}Cache${RST} ${VAL}\$${R_CACHE}${RST}  ${LBL}Write${RST} ${VAL}\$${R_WRITE}${RST}  ${LBL}Out${RST} ${VAL}\$${R_OUT}${RST}   ${LBL}API${RST} ${VAL}${API_FMT}${RST}  ${LBL}Max${RST} ${VAL}${COST_FMT}${RST}"
if [ -n "$USAGE_LINE" ]; then
  row "$USAGE_LINE"
fi
printf "%b\n" "$HLINE"

# ── Lower Section (frameless activity lines) ──
if [ "$SHOW_TOOLS" != "0" ] && [ -n "$R_TOOLS" ]; then
  printf "%b\n" "  ${R_TOOLS}"
fi
if [ "$SHOW_AGENTS" != "0" ] && [ -n "$R_AGENTS" ]; then
  printf "%b\n" "  ${R_AGENTS}"
fi
if [ "$SHOW_TODOS" != "0" ] && [ -n "$R_TODOS" ]; then
  printf "%b\n" "  ${R_TODOS}"
fi
