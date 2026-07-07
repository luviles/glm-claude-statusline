#!/usr/bin/env bash
# Claude Code statusline (v2) — 3-line WKS/SES/QTA layout.
# stdin:  JSON payload from Claude Code (model, workspace, cost, context_window, ...).
# stdout: 3-line ANSI-colored status string consumed by Claude Code's statusline.
#
# Rendering design (gradient gauges, palette, humanized resets, indent/alignment,
# output mechanism) transplanted from v2_baseline.txt. GLM quota fetch
# (endpoint, auth, 60s cache, jq schema, [1m] model branding) preserved from v1.

set -u
LANG=en_US.UTF-8

# === Color palette (R;G;B) — spliced into literal \033[38;2;R;G;Bm, emitted by printf '%b' ===
C_WKS="130;170;255"     # WKS label
C_MODEL="125;162;247"   # model value
C_PWD="111;184;159"     # folder value
C_BRANCH="122;153;78"   # branch + line-changes (git-themed)
C_SES="245;194;107"     # SES label
C_TIME="166;150;255"    # session time
C_COST="205;168;96"     # session cost
C_QTA="240;138;90"      # QTA label
SEP=" \033[2;37m❙\033[0m "   # item separator (dim gray ❙, U+2759)

# ── Utility ──────────────────────────────────────────────────

# Cache age in seconds; 999999 if missing. Portable BSD/GNU stat.
file_age() {
  [ -f "$1" ] || { echo 999999; return; }
  echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0) ))
}

# 3-stop green→amber→red gradient (pos 0–100). Returns "R;G;B".
gradient_color() {
  local pos=$1 r g b
  if (( pos <= 50 )); then
    r=$(( 157 + (245 - 157) * pos / 50 ))
    g=$(( 226 + (194 - 226) * pos / 50 ))
    b=$(( 208 + (107 - 208) * pos / 50 ))
  else
    local t=$(( pos - 50 ))
    r=$(( 245 + (217 - 245) * t / 50 ))
    g=$(( 194 + (91 - 194) * t / 50 ))
    b=$(( 107 + (91 - 107) * t / 50 ))
  fi
  echo "${r};${g};${b}"
}

# Bar of ▰/▱ with per-cell gradient. make_bar <pct:0-100> [width:20].
make_bar() {
  local pct=${1:-0} w=${2:-20}
  local filled=$(( pct * w / 100 )) bar="" i bp color
  for (( i=0; i<w; i++ )); do
    bp=$(( i * 100 / (w - 1) ))
    color=$(gradient_color "$bp")
    (( i < filled )) \
      && bar+="\033[38;2;${color}m▰\033[0m" \
      || bar+="\033[2;37m▱\033[0m"
  done
  echo "$bar"
}

# ISO timestamp → "Today 3:00PM" / "Tomorrow 9:30AM" / "Wed" / "02/20".
format_reset_time() {
  [ -z "$1" ] || [ "$1" = "null" ] && return
  python3 -c "
from datetime import datetime, timedelta
try:
    dt = datetime.fromisoformat('$1').astimezone()
    now = datetime.now().astimezone()
    delta = (dt.date() - now.date()).days
    if delta == 0: day = 'Today'
    elif delta == 1: day = 'Tomorrow'
    elif delta <= 7: day = dt.strftime('%a')
    else: day = dt.strftime('%m/%d')
    print(f'{day} {dt.strftime(\"%-I:%M%p\")}')
except: pass
" 2>/dev/null
}

# ms-epoch → ISO-8601 (local tz, colon offset) for format_reset_time.
# Empty/null/0 → no output (caller omits reset). Tries GNU date -d @ then BSD date -r.
ms_to_iso() {
  local ms="${1:-}"
  [ -z "$ms" ] || [ "$ms" = "null" ] || [ "$ms" = "0" ] && return
  local s=$(( ms / 1000 ))
  date -d "@${s}" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null \
    || date -r "$s" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null
}

# ── Parse JSON input (single jq call, newline-delimited) ─────

input=$(cat)
{
  read -r model
  read -r cwd
  read -r ctx_pct
  read -r cost_usd
  read -r duration_ms
} < <(echo "$input" | jq -r '
  (.model.display_name // .model.id // "?"),
  (.workspace.current_dir // .cwd // ""),
  (.context_window.used_percentage // 0 | tonumber | floor | tostring),
  (.cost.total_cost_usd // ""),
  (.cost.total_duration_ms // "")
' 2>/dev/null)

# GLM-specific model-name branding (v1)
model="${model// (1M context)/[1m]}"
model="${model:-?}"
[ -z "$cwd" ] && cwd=$PWD

# ── WKS: folder, git branch, line-changed ────────────────────

folder=$(basename "$cwd")
git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)

lines_changed=""
if [ -n "$git_branch" ]; then
  lines_changed=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" diff --numstat HEAD 2>/dev/null \
    | awk '{if($1=="-"||$2=="-")next; a+=$1; d+=$2} END{printf "+%d -%d", a+0, d+0}')
fi

# ── SES: cost, time, context ─────────────────────────────────

cost_str="\$0.00"
[ -n "$cost_usd" ] && [ "$cost_usd" != "null" ] \
  && cost_str=$(awk "BEGIN{c=$cost_usd; if(c<0.01) printf \"<\$0.01\"; else printf \"\$%.2f\",c}")

time_str="0s"
if [ -n "$duration_ms" ] && [ "$duration_ms" != "null" ]; then
  s=$(( ${duration_ms%.*} / 1000 ))
  if   (( s < 60 ));   then time_str="${s}s"
  elif (( s < 3600 )); then time_str="$(( s/60 ))m $(( s%60 ))s"
  else                       time_str="$(( s/3600 ))h $(( s%3600/60 ))m"; fi
fi

ctx_pct=${ctx_pct:-0}

# ── QTA: GLM quota (cached 60s) ──────────────────────────────

cache_file="/tmp/.claude-quota-cache"

if (( $(file_age "$cache_file") >= 60 )); then
  base_url="${ANTHROPIC_BASE_URL:-}"
  auth_token="${ANTHROPIC_AUTH_TOKEN:-}"
  if [ -n "$base_url" ] && [ -n "$auth_token" ]; then
    base_domain=$(echo "$base_url" | sed -E 's|(https?://[^/]+).*|\1|')
    quota_url="${base_domain}/api/monitor/usage/quota/limit"
    quota_json=$(curl -s --max-time 3 \
      -H "Authorization: ${auth_token}" \
      -H "Accept-Language: en-US,en" \
      "$quota_url" 2>/dev/null)
    [ -n "$quota_json" ] && printf '%s' "$quota_json" > "$cache_file"
  fi
fi

if [ ! -f "$cache_file" ] || [ ! -s "$cache_file" ]; then
  quota_json=""
else
  quota_json=$(< "$cache_file")
fi

p5="" reset5_ms="" p7="" reset7_ms="" pm="" resetm_ms=""
if [ -n "$quota_json" ]; then
  {
    read -r p5
    read -r reset5_ms
    read -r p7
    read -r reset7_ms
    read -r pm
    read -r resetm_ms
  } < <(echo "$quota_json" | jq -r '
    ([.data.limits[] | select(.type=="TOKENS_LIMIT" and .unit==3)][0] // null) as $t5
    | ([.data.limits[] | select(.type=="TOKENS_LIMIT" and .unit==6)][0] // null) as $t7
    | ([.data.limits[] | select(.type=="TIME_LIMIT")][0] // null) as $m
    | (
      (if $t5 then ($t5.percentage   // 0 | tonumber | floor | tostring) else "" end),
      (if $t5 then ($t5.nextResetTime // 0 | tonumber | floor | tostring) else "" end),
      (if $t7 then ($t7.percentage   // 0 | tonumber | floor | tostring) else "" end),
      (if $t7 then ($t7.nextResetTime // 0 | tonumber | floor | tostring) else "" end),
      (if $m  then ($m.percentage    // 0 | tonumber | floor | tostring) else "" end),
      (if $m  then ($m.nextResetTime // 0 | tonumber | floor | tostring) else "" end)
    )
  ' 2>/dev/null)
fi

# Humanize reset times (ms → ISO → "Today 3:00PM" …). Empty if unavailable.
rest5="" rest7="" restm=""
if [ -n "$reset5_ms" ] && [ "$reset5_ms" != "0" ]; then
  r=$(format_reset_time "$(ms_to_iso "$reset5_ms")"); [ -n "$r" ] && rest5=" ↻ ${r}"
fi
if [ -n "$reset7_ms" ] && [ "$reset7_ms" != "0" ]; then
  r=$(format_reset_time "$(ms_to_iso "$reset7_ms")"); [ -n "$r" ] && rest7=" ↻ ${r}"
fi
if [ -n "$resetm_ms" ] && [ "$resetm_ms" != "0" ]; then
  r=$(format_reset_time "$(ms_to_iso "$resetm_ms")"); [ -n "$r" ] && restm=" ↻ ${r}"
fi

# ── Bar-width alignment: SES end == longest QTA line end ───────────────────
# Defaults: context gauge 10 cells, each quota gauge 20 cells. The 3 quota
# gauges are always equal-width. If SES reaches farther, grow the quota gauges
# so the longest quota line ends where SES does; if a quota line reaches farther,
# grow the context gauge so SES ends where the longest quota line does.
# Every glyph here is a non-emoji 1-col symbol (▣ ◆ ◇ ❙ ↻ ▰ ▱), so ASCII
# segment width == ${#var} and the icon labels reduce to fixed constants.
pct3d_ctx=$(printf '%3d' "$ctx_pct")
ses_fixed=$(( 7 + ${#cost_str} + 3 + ${#time_str} ))         # "◆ SES: "(7) + cost + SEP + time
[ -n "$lines_changed" ] && ses_fixed=$(( ses_fixed + 3 + ${#lines_changed} ))
ses_fixed=$(( ses_fixed + 3 + 1 + ${#pct3d_ctx} + 1 ))        # + SEP + " <pct>%"
# QTA fixed width excl. bar = prefix(11) + " "(1) + pct3d(3) + "%"(1) = 16, + reset suffix
q5fx=0 q7fx=0 qmfx=0
[ -n "$p5" ] && q5fx=$(( 16 + ${#rest5} ))
[ -n "$p7" ] && q7fx=$(( 16 + ${#rest7} ))
[ -n "$pm" ] && qmfx=$(( 16 + ${#restm} ))
qmax=$q5fx; [ "$q7fx" -gt "$qmax" ] && qmax=$q7fx; [ "$qmfx" -gt "$qmax" ] && qmax=$qmfx

ctx_default=10
qta_default=20
if [ "$qmax" -gt 0 ] && [ $(( ses_fixed + ctx_default )) -ge $(( qmax + qta_default )) ]; then
  ctx_bar=$ctx_default
  qta_bar=$(( ses_fixed + ctx_default - qmax ))              # SES longer → grow quota bars
elif [ "$qmax" -gt 0 ]; then
  qta_bar=$qta_default
  ctx_bar=$(( qmax + qta_default - ses_fixed ))              # SES shorter → grow context bar
else
  ctx_bar=$ctx_default                                        # no quota data → keep defaults
  qta_bar=$qta_default
fi

# ── Line assembly (literal \033; make_bar/gradient_color evaluated via $(…)) ─

# Line 1 — WKS: model / folder / branch
line_wks="\033[38;2;${C_WKS}m▣ WKS:\033[0m \033[38;2;${C_MODEL}m${model}\033[0m"
line_wks+="${SEP}\033[38;2;${C_PWD}m${folder}\033[0m"
[ -n "$git_branch" ] && line_wks+="${SEP}\033[38;2;${C_BRANCH}m${git_branch}\033[0m"

# Line 2 — SES: cost / time / line-changed / context [gauge + %]
line_ses="\033[38;2;${C_SES}m◆ SES:\033[0m \033[38;2;${C_COST}m${cost_str}\033[0m"
line_ses+="${SEP}\033[38;2;${C_TIME}m${time_str}\033[0m"
[ -n "$lines_changed" ] && line_ses+="${SEP}\033[38;2;${C_BRANCH}m${lines_changed}\033[0m"
line_ses+="${SEP}$(make_bar "$ctx_pct" "$ctx_bar") \033[38;2;$(gradient_color "$ctx_pct")m${pct3d_ctx}%\033[0m"

# Line 3 — QTA: 5h (label) / 7d / MCP
# Sub-lines start with an ANSI escape (not a space) so Claude Code's per-line
# leading-whitespace trim leaves the 7-col indent intact; indent sits inside the
# dim span. Tags 5h/7d/MCP occupy a 3-col field so gauges align in one column.
line_qta_5h=""
if [ -n "$p5" ]; then
  line_qta_5h="\033[38;2;${C_QTA}m◇ QTA:\033[0m \033[2;37m5h \033[0m $(make_bar "$p5" "$qta_bar") \033[38;2;$(gradient_color "$p5")m$(printf '%3d' "$p5")%${rest5}\033[0m"
fi

line_qta_7d=""
if [ -n "$p7" ]; then
  line_qta_7d="\033[2;37m       7d \033[0m $(make_bar "$p7" "$qta_bar") \033[38;2;$(gradient_color "$p7")m$(printf '%3d' "$p7")%${rest7}\033[0m"
fi

line_qta_mcp=""
if [ -n "$pm" ]; then
  line_qta_mcp="\033[2;37m       MCP\033[0m $(make_bar "$pm" "$qta_bar") \033[38;2;$(gradient_color "$pm")m$(printf '%3d' "$pm")%${restm}\033[0m"
fi

# ── Output ───────────────────────────────────────────────────

output="$line_wks\n$line_ses"
if [ -n "$line_qta_5h" ] || [ -n "$line_qta_7d" ] || [ -n "$line_qta_mcp" ]; then
  [ -n "$line_qta_5h"  ] && output+="\n${line_qta_5h}"
  [ -n "$line_qta_7d"  ] && output+="\n${line_qta_7d}"
  [ -n "$line_qta_mcp" ] && output+="\n${line_qta_mcp}"
fi
printf '%b\n\n\n' "$output"
