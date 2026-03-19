#!/bin/bash
input=$(cat)

# ── Colors (true color) ──
RED="\033[38;2;255;85;85m"
YEL="\033[38;2;230;200;0m"
GRN="\033[38;2;0;175;80m"
CYN="\033[38;2;86;182;194m"
BLU="\033[38;2;0;153;255m"
MAG="\033[38;2;180;140;255m"
WHT="\033[38;2;220;220;220m"
DIM="\033[2m"
RST="\033[0m"

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

# ── Helpers ──
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
  local content="$1"
  local vlen
  vlen=$(vis_len "$content")
  local pad=$((W - vlen))
  [ "$pad" -lt 0 ] && pad=0
  echo -e "${DIM}│${RST}${content}$(printf '%*s' "$pad" '')${DIM}│${RST}"
}

HLINE=$(printf "%${W}s" '' | sed 's/ /─/g')
HDIV="${DIM}┌${HLINE}┐${RST}"
MDIV="${DIM}├${HLINE}┤${RST}"
FDIV="${DIM}└${HLINE}┘${RST}"

# ── Context Window ──
PCT=$(jval '.context_window.used_percentage' '0' | cut -d. -f1)
CTX_SIZE=$(jval '.context_window.context_window_size' '1000000')
CUR_IN=$(jval '.context_window.current_usage.input_tokens' '0')
CUR_OUT=$(jval '.context_window.current_usage.output_tokens' '0')
CACHE_WR=$(jval '.context_window.current_usage.cache_creation_input_tokens' '0')
CACHE_RD=$(jval '.context_window.current_usage.cache_read_input_tokens' '0')
CTX_USED=$((CUR_IN + CUR_OUT + CACHE_WR + CACHE_RD))

if [ "$PCT" -ge 80 ]; then CTX_CLR=$RED
elif [ "$PCT" -ge 50 ]; then CTX_CLR=$YEL
else CTX_CLR=$GRN; fi

FILLED=$((PCT * 30 / 100))
BAR="${CTX_CLR}$(printf '%*s' "$FILLED" '' | sed 's/ /●/g')${DIM}$(printf '%*s' "$((30 - FILLED))" '' | sed 's/ /○/g')${RST}"

# ── Session Info ──
TOTAL_COST=$(jval '.cost.total_cost_usd' '0')
DUR_MS=$(jval '.cost.total_duration_ms' '0')
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
    GIT_INFO="  ${DIM}│${RST}  ${GRN}${GIT_BRANCH}${RST}${GIT_DIRTY}"
  fi
fi

# ── Effort Level ──
EFFORT_INFO=""
if [ "$SHOW_EFFORT" != "0" ]; then
  EFFORT=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null)
  case "$EFFORT" in
    high)   EFFORT_INFO="  ${DIM}│${RST}  ${MAG}● ${EFFORT}${RST}" ;;
    medium) EFFORT_INFO="  ${DIM}│${RST}  ${DIM}◑ ${EFFORT}${RST}" ;;
    low)    EFFORT_INFO="  ${DIM}│${RST}  ${DIM}◔ ${EFFORT}${RST}" ;;
    *)      EFFORT_INFO="  ${DIM}│${RST}  ${DIM}◑ ${EFFORT}${RST}" ;;
  esac
fi

# ── Token Speed ──
# Note: CUR_OUT is context-window-scoped output tokens, not cumulative session total.
# Speed readings reset after context compaction. This is a known limitation.
SPEED_INFO=""
if [ "$SHOW_SPEED" != "0" ]; then
  SPEED_CACHE="/tmp/claude/cc-speed-${SESSION_ID}.dat"
  NOW_MS=$(($(date +%s) * 1000))
  if [ -f "$SPEED_CACHE" ]; then
    PREV_OUT=$(sed -n '1p' "$SPEED_CACHE")
    PREV_MS=$(sed -n '2p' "$SPEED_CACHE")
    DELTA_T=$((NOW_MS - PREV_MS))
    DELTA_O=$((CUR_OUT - PREV_OUT))
    if [ "$DELTA_O" -lt 0 ]; then
      : # Context compaction — skip, cache will be overwritten below
    elif [ "$DELTA_T" -gt 0 ] && [ "$DELTA_O" -gt 0 ]; then
      SPEED=$(echo "scale=1; $DELTA_O * 1000 / $DELTA_T" | bc -l)
      SPEED_INFO="  ${DIM}│${RST}  ${WHT}${SPEED} tok/s${RST}"
    fi
  fi
  printf '%s\n%s\n' "$CUR_OUT" "$NOW_MS" > "$SPEED_CACHE"
fi

# ── Cost Breakdown (transcript parse with 5s cache) ──
P_CACHE=0; P_WRITE=0; P_OUT=0

mkdir -p /tmp/claude
CACHE_FILE="/tmp/claude/cc-cost-${SESSION_ID}.dat"
PARSE=1
if [ -f "$CACHE_FILE" ]; then
  CACHE_MOD=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  [ $((NOW - CACHE_MOD)) -lt 5 ] && PARSE=0
fi

if [ "$PARSE" -eq 1 ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  COST_DATA=$(TRANSCRIPT_PATH="$TRANSCRIPT" TOTAL_COST_USD="$TOTAL_COST" python3 << 'PYEOF'
import json, sys, os

transcript = os.environ.get("TRANSCRIPT_PATH", "")
total_cost = float(os.environ.get("TOTAL_COST_USD", "0"))

if not transcript or not os.path.isfile(transcript) or total_cost <= 0:
    print("0\n0\n0\n0.00\n0.00\n0.00")
    sys.exit(0)

# API rate weights (relative pricing structure per MTok)
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
with open(transcript) as f:
    for line in f:
        try:
            e = json.loads(line)
            msg = e.get("message", {})
            if msg.get("usage") and msg.get("id"):
                by_id[msg["id"]] = msg
        except Exception:
            pass

# Calculate API costs directly
c_cache = 0.0  # cache reads
c_write = 0.0  # cache writes + base input
c_out = 0.0    # output

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

print(f"{c_cache:.2f}")
print(f"{c_write:.2f}")
print(f"{c_out:.2f}")
print(f"{api_total:.2f}")
PYEOF
  )

  if [ -n "$COST_DATA" ]; then
    R_CACHE=$(echo "$COST_DATA" | sed -n '1p')
    R_WRITE=$(echo "$COST_DATA" | sed -n '2p')
    R_OUT=$(echo "$COST_DATA" | sed -n '3p')
    R_API=$(echo "$COST_DATA" | sed -n '4p')
    printf '%s\n%s\n%s\n%s\n' "$R_CACHE" "$R_WRITE" "$R_OUT" "$R_API" > "$CACHE_FILE"
  fi
else
  if [ -f "$CACHE_FILE" ]; then
    R_CACHE=$(sed -n '1p' "$CACHE_FILE")
    R_WRITE=$(sed -n '2p' "$CACHE_FILE")
    R_OUT=$(sed -n '3p' "$CACHE_FILE")
    R_API=$(sed -n '4p' "$CACHE_FILE")
  fi
fi

# Defaults
: "${R_CACHE:=0.00}" "${R_WRITE:=0.00}" "${R_OUT:=0.00}" "${R_API:=0.00}"

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
      blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
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
    local f=$(printf '%*s' "$filled" '' | sed 's/ /●/g')
    local e=$(printf '%*s' "$empty" '' | sed 's/ /○/g')
    echo -ne "${clr}${f}${DIM}${e}${RST}"
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
  USAGE_CACHE="/tmp/claude/cc-usage-cache.json"
  USAGE_DATA=""
  NEEDS_FETCH=true

  if [ -f "$USAGE_CACHE" ]; then
    CACHE_MOD_U=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0)
    NOW_U=$(date +%s)
    CACHE_AGE=$((NOW_U - CACHE_MOD_U))
    if jq -e '.five_hour' "$USAGE_CACHE" &>/dev/null; then
      [ "$CACHE_AGE" -lt 60 ] && NEEDS_FETCH=false
    else
      [ "$CACHE_AGE" -lt 15 ] && NEEDS_FETCH=false
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
    FIVE_PCT=$(echo "$USAGE_DATA" | jq -r '.five_hour.utilization // 0' | cut -d. -f1)
    FIVE_RESET_ISO=$(echo "$USAGE_DATA" | jq -r '.five_hour.resets_at // empty')
    FIVE_RESET=$(format_reset_time "$FIVE_RESET_ISO" "time")
    FIVE_BAR=$(build_usage_bar "$FIVE_PCT")

    SEVEN_PCT=$(echo "$USAGE_DATA" | jq -r '.seven_day.utilization // 0' | cut -d. -f1)
    SEVEN_RESET_ISO=$(echo "$USAGE_DATA" | jq -r '.seven_day.resets_at // empty')
    SEVEN_RESET=$(format_reset_time "$SEVEN_RESET_ISO" "datetime")
    SEVEN_BAR=$(build_usage_bar "$SEVEN_PCT")

    FIVE_CLR=$GRN; [ "$FIVE_PCT" -ge 50 ] && FIVE_CLR=$YEL; [ "$FIVE_PCT" -ge 90 ] && FIVE_CLR=$RED
    SEVEN_CLR=$GRN; [ "$SEVEN_PCT" -ge 50 ] && SEVEN_CLR=$YEL; [ "$SEVEN_PCT" -ge 90 ] && SEVEN_CLR=$RED

    USAGE_LINE="  ${WHT}current${RST} ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${RST}"
    [ -n "$FIVE_RESET" ] && USAGE_LINE+=" ${DIM}⟳${RST} ${WHT}${FIVE_RESET}${RST}"
    USAGE_LINE+="  ${DIM}│${RST}  ${WHT}weekly${RST} ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${RST}"
    [ -n "$SEVEN_RESET" ] && USAGE_LINE+=" ${DIM}⟳${RST} ${WHT}${SEVEN_RESET}${RST}"
  fi

fi

# ── Output ──
echo -e "$HDIV"
row "  CONTEXT  ${BAR}  ${CTX_CLR}${PCT}%${RST}  ${DIM}│${RST}  $(fmt_k $CTX_USED)/$(fmt_k $CTX_SIZE)"
echo -e "$MDIV"
row "  ${DIM}Cost:${RST} ${DIM}Cache${RST} \$${R_CACHE} ${DIM}Write${RST} \$${R_WRITE} ${DIM}Out${RST} \$${R_OUT} ${DIM}│${RST} ${DIM}API${RST} ${API_FMT} ${DIM}Max${RST} ${COST_FMT}"
echo -e "$MDIV"
row "  ${BLU}${MODEL_NAME}${RST}  ${DIM}│${RST}  ${CYN}${PROJECT_NAME}${RST}  ${DIM}·${RST}  ${CWD_SHORT}${GIT_INFO}"
echo -e "$MDIV"
row "  ${DIM}Duration:${RST} ${TIME_FMT}  ${DIM}│${RST}  ${DIM}CC:${RST} ${VERSION}${EFFORT_INFO}${SPEED_INFO}"
if [ -n "$USAGE_LINE" ]; then
  echo -e "$MDIV"
  row "$USAGE_LINE"
fi
echo -e "$FDIV"
