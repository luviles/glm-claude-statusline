#!/usr/bin/env bash
# Claude Code statusline.
# stdin:  JSON payload from Claude Code (model, workspace, cost, context_window, ...)
# stdout: single-line ANSI-colored status string.

set -u
LANG=en_US.UTF-8

# ─── Input: read all needed fields with one jq call ───────────────────────────
input=$(cat)

IFS=$'\x1f' read -r \
  model cwd ctx_pct ctx_tokens <<<"$(jq -r '[
    .model.display_name // .model.id // "?",
    .workspace.current_dir // .cwd // "",
    (.context_window.used_percentage // 0 | tostring),
    ( (.context_window.current_usage // {})
      | ( (.input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.cache_read_input_tokens // 0)
        + (.output_tokens // 0) )
      | tostring )
  ] | join("")' <<<"$input" 2>/dev/null)"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Format a token count with k/M suffix.
human_tokens() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n+0 >= 1000000) printf "%.1fM", n/1000000;
    else if (n+0 >= 1000) printf "%.0fk", n/1000;
    else printf "%d", n;
  }'
}

# Round a percentage to an integer.
fmt_pct() { awk -v p="${1:-0}" 'BEGIN { printf "%.0f", p+0 }'; }

# Format an epoch timestamp with strftime; empty/0 → em-dash.
fmt_epoch() {
  if [ -z "${1:-}" ] || [ "${1:-0}" = "0" ]; then echo "—"; return; fi
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null || echo "—"
}

# ─── ANSI palette ─────────────────────────────────────────────────────────────
M=$'\033[38;5;213m'   # model        — pink
F=$'\033[38;5;75m'    # folder       — sky blue
B=$'\033[38;5;120m'   # branch       — green
C=$'\033[38;5;221m'   # context      — amber
H5=$'\033[38;5;208m'  # token 5h     — orange
D7=$'\033[38;5;203m'  # token weekly — coral
TL=$'\033[38;5;122m'  # tool quota   — teal
S=$'\033[38;5;255m'   # separator    — white
R=$'\033[0m'
SEP=" ${S}❙${R} "

# ─── Segment: model ───────────────────────────────────────────────────────────
model="${model// (1M context)/[1m]}"
seg_model="${M}🤖 ${model}${R}"

# ─── Segment: folder ──────────────────────────────────────────────────────────
[ -z "$cwd" ] && cwd=$PWD
folder=$(basename "$cwd")
seg_folder="${F}📁 ${folder}${R}"

# ─── Segment: git branch (omitted when not a repo) ───────────────────────────
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
if [ -n "$branch" ]; then
  seg_branch="${B}🌿 ${branch}${R}"
fi

# ─── Segment: context window ──────────────────────────────────────────────────
seg_ctx="${C}🧠 $(fmt_pct "$ctx_pct")% ($(human_tokens "$ctx_tokens") tokens)${R}"

# ─── Segment: ZAI quota (cached, refreshed every 60s) ─────────────────────────
cache_file="/tmp/.claude-quota-cache"
cache_stale=0

if [ -f "$cache_file" ]; then
  cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
  [ "$cache_age" -ge 60 ] && cache_stale=1
else
  cache_stale=1
fi

if [ "$cache_stale" -eq 1 ]; then
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
  quota_json=$(cat "$cache_file")
fi

if [ -n "$quota_json" ]; then
    IFS=$'\x1f' read -r \
      pct_5h reset_5h_ms \
      pct_7d reset_7d_ms \
      tool_current tool_total reset_tool_ms <<<"$(
        echo "$quota_json" | jq -r '
          [.data.limits[] | select(.type=="TOKENS_LIMIT" and .unit==3)][0] as $t5 |
          [.data.limits[] | select(.type=="TOKENS_LIMIT" and .unit==6)][0] as $t7 |
          [.data.limits[] | select(.type=="TIME_LIMIT")][0] as $m |
          [$t5.percentage // "", $t5.nextResetTime // "",
           $t7.percentage // "", $t7.nextResetTime // "",
           $m.currentValue // "", $m.usage // "", $m.nextResetTime // ""]
          | join("")
        ' 2>/dev/null
      )"

    if [ -n "$pct_5h" ]; then
      reset_ts=$(( ${reset_5h_ms:-0} / 1000 ))
      reset_5h=$(fmt_epoch "$reset_ts" "%H:%M")
      seg_tokens="${H5}⏱️ $(fmt_pct "$pct_5h")% (${reset_5h})${R}"
    fi

    if [ -n "$pct_7d" ]; then
      reset_ts=$(( ${reset_7d_ms:-0} / 1000 ))
      reset_7d=$(fmt_epoch "$reset_ts" "%m/%d %H:%M")
      seg_weekly="${D7}📆 $(fmt_pct "$pct_7d")% (${reset_7d})${R}"
    fi

    if [ -n "$tool_current" ]; then
      reset_ts=$(( ${reset_tool_ms:-0} / 1000 ))
      reset_tool=$(fmt_epoch "$reset_ts" "%m/%d %H:%M")
      seg_tool="${TL}🔧 ${tool_current}/${tool_total} (${reset_tool})${R}"
    fi
  fi

# ─── Render ───────────────────────────────────────────────────────────────────
parts=("$seg_model" "$seg_folder")
[ -n "${seg_branch:-}" ] && parts+=("$seg_branch")
parts+=("$seg_ctx")
[ -n "${seg_tokens:-}" ] && parts+=("$seg_tokens")
[ -n "${seg_weekly:-}" ] && parts+=("$seg_weekly")
[ -n "${seg_tool:-}"   ] && parts+=("$seg_tool")

out="${parts[0]}"
for p in "${parts[@]:1}"; do out+="${SEP}${p}"; done
echo "$out"
