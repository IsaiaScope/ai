#!/usr/bin/env bash
# humanize pipes a draft through an agent CLI and prints the result. No writes.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/agent" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AGENT_LOG"
echo "UMANIZZATO"
STUB
chmod +x "$T/agent"
export AGENT_BIN="$T/agent" AGENT_LOG="$T/log"

printf '# T\n\n**HOOK**\n\n* bozza\n' > "$T/d.draft.md"
printf '# Voice\n\n> come parlo io\n' > "$T/voice.md"

eval "$(sed -n '/^humanize() {/,/^}/p' ./scaletta.sh)"
type humanize >/dev/null 2>&1 || { echo "FAIL: humanize not defined"; exit 1; }

out=$(AGENT=claude humanize "$T/d.draft.md" "$T/voice.md")
printf '%s' "$out" | grep -q 'UMANIZZATO' || { echo "FAIL: did not return agent output"; rc=1; }
[ -f "$T/d.md" ] && { echo "FAIL: humanize wrote a file; bash must own writes"; rc=1; }

log=$(cat "$AGENT_LOG")
printf '%s' "$log" | grep -q 'come parlo io' || { echo "FAIL: voice profile not in the prompt"; rc=1; }
printf '%s' "$log" | grep -q 'bozza'         || { echo "FAIL: draft not in the prompt"; rc=1; }
printf '%s' "$log" | grep -qi 'non ristrutturare\|do not restructure' \
  || { echo "FAIL: missing the do-not-restructure constraint"; rc=1; }

out=$(AGENT=claude humanize "$T/missing.md" "$T/voice.md" 2>/dev/null); code=$?
[ "$code" -ne 0 ] || { echo "FAIL: missing draft should fail"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: humanize"
exit "$rc"
