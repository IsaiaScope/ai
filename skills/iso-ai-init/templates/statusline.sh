#!/usr/bin/env bash
# Claude Code status line
# Receives JSON on stdin from Claude Code

input=$(cat)

# Directory: shorten to last 2 segments
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
[ -z "$cwd" ] && cwd=$(pwd)
short_cwd="${cwd/#$HOME/\~}"
dir=$(echo "$short_cwd" | awk -F'/' '{
  n=NF; if (n<=2) { print $0 }
  else { print "…/" $(n-1) "/" $n }
}')

# Git branch
branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)

# Cost
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Context % — use used_percentage directly, fall back to 100-remaining
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -z "$used" ]; then
  remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
  [ -n "$remaining" ] && used=$(awk -v r="$remaining" 'BEGIN { printf "%.0f", 100 - r }')
fi

# Colors
reset='\033[0m'
cyan='\033[36m'
yellow='\033[33m'
green='\033[32m'
magenta='\033[35m'
red='\033[31m'
orange='\033[38;5;172m'

# Caveman: savings if available, else mode label
caveman_suffix=""
FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
if [ -f "$FLAG" ] && [ ! -L "$FLAG" ]; then
  MODE=$(head -c 64 "$FLAG" 2>/dev/null | tr -d '\n\r' | tr -cd 'a-z0-9-')
  SAVINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-statusline-suffix"
  if [ -f "$SAVINGS_FILE" ] && [ ! -L "$SAVINGS_FILE" ]; then
    SAVINGS=$(head -c 64 "$SAVINGS_FILE" 2>/dev/null | tr -d '\000-\037')
    [ -n "$SAVINGS" ] && caveman_suffix="${orange}${SAVINGS}${reset}"
  fi
  if [ -z "$caveman_suffix" ] && [ -n "$MODE" ] && [ "$MODE" != "off" ]; then
    LABEL=$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')
    caveman_suffix="${orange}${LABEL}${reset}"
  fi
fi

# Build
SEP="   "
parts="${cyan}${dir}${reset}"
[ -n "$branch" ] && parts="${parts}${SEP}${yellow}${branch}${reset}"

if [ -n "$used" ]; then
  [ "$used" -ge 90 ] && ctx_color="$red" || ctx_color="$magenta"
  parts="${parts}${SEP}${ctx_color}ctx:${used}%${reset}"
fi

[ -n "$cost" ] && parts="${parts}${SEP}${green}$(awk -v c="$cost" 'BEGIN { printf "$%.2f", c }')${reset}"
[ -n "$caveman_suffix" ] && parts="${parts}${SEP}${caveman_suffix}"

printf "%b\n" "$parts"
