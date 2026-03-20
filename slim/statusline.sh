#!/bin/bash
input=$(cat)

# ── Colors ──
RED="\033[31m"
YEL="\033[33m"
GRN="\033[32m"
CYN="\033[36m"
DIM="\033[2m"
RST="\033[0m"

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
BAR="${CTX_CLR}$(printf '%*s' "$FILLED" '' | sed 's/ /▰/g')${DIM}$(printf '%*s' "$((30 - FILLED))" '' | sed 's/ /▱/g')${RST}"

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

# ── Cost Breakdown (transcript parse with 5s cache) ──
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

# ── Output ──
echo -e "$HDIV"
row "  CONTEXT  ${BAR}  ${CTX_CLR}${PCT}%${RST}  ${DIM}│${RST}  $(fmt_k "$CTX_USED")/$(fmt_k "$CTX_SIZE")"
echo -e "$MDIV"
row "  ${DIM}Cost:${RST} ${DIM}Cache${RST} \$${R_CACHE} ${DIM}Write${RST} \$${R_WRITE} ${DIM}Out${RST} \$${R_OUT} ${DIM}│${RST} ${DIM}API${RST} ${API_FMT} ${DIM}Max${RST} ${COST_FMT}"
echo -e "$MDIV"
row "  ${CYN}${MODEL_NAME}${RST}  ${DIM}│${RST}  ${GRN}${PROJECT_NAME}${RST}  ${DIM}·${RST}  ${CWD_SHORT}"
echo -e "$MDIV"
row "  ${DIM}Duration:${RST} ${TIME_FMT}  ${DIM}│${RST}  ${DIM}CC Version:${RST} ${VERSION}"
echo -e "$FDIV"
