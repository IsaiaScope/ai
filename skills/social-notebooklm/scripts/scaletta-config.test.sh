#!/usr/bin/env bash
# scaletta.sh resolves personal paths by convention, not by hardcoding.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
S=./scaletta.sh
bash -n "$S" || { echo "FAIL: syntax error"; rc=1; }
grep -q '/Volumes/Crucial-4T' "$S" && { echo "FAIL: personal path still hardcoded"; rc=1; }
grep -q 'OUT_BASE="\./content"' "$S" || { echo "FAIL: OUT_BASE default is not ./content"; rc=1; }
# --help exits non-zero by design; pipefail would misreport a matching grep.
help_out=$("$S" --help 2>&1 || true)
printf '%s' "$help_out" | grep -q './content' || { echo "FAIL: --help does not show the new default"; rc=1; }
grep -q 'script-long\.md' "$S" && { echo "FAIL: still writes script-long.md"; rc=1; }
grep -q 'script-short\.md' "$S" && { echo "FAIL: still writes script-short.md"; rc=1; }
grep -q 'scaletta-long' "$S" || { echo "FAIL: does not write scaletta-long"; rc=1; }
grep -q 'scaletta-short' "$S" || { echo "FAIL: does not write scaletta-short"; rc=1; }
grep -q 'VOICE_FILE="\./voice/voice\.md"' "$S" || { echo "FAIL: VOICE_FILE default missing"; rc=1; }
T=$(mktemp -d)
out=$("$S" --voice "$T/nope.md" 2>&1); code=$?
[ "$code" -ne 0 ] || { echo "FAIL: missing voice profile did not halt"; rc=1; }
printf '%s' "$out" | grep -q 'voice profile' || { echo "FAIL: unhelpful error: $out"; rc=1; }
printf '%s' "$out" | grep -qi 'notebooklm ask' && { echo "FAIL: reached NotebookLM before failing"; rc=1; }
rm -rf "$T"
for v in LONG_PROMPT SHORT_PROMPT; do
  line=$(grep -m1 "^$v=" "$S")
  printf '%s' "$line" | grep -q 'esempio quotidiano' || { echo "FAIL: $v has no Ramp rule"; rc=1; }
  printf '%s' "$line" | grep -q 'PRIMA' || { echo "FAIL: $v does not state the ordering"; rc=1; }
done
grep -m1 '^LONG_PROMPT=' "$S" | grep -q 'HOOK' || { echo "FAIL: LONG_PROMPT lost its HOOK instruction"; rc=1; }
# The two deliverables land in OUT_DIR; the draft is scaffolding and must not.
grep -q 'final_file="\$OUT_DIR/scaletta-\$kind\.md"' "$S" \
  || { echo "FAIL: the final is not written to OUT_DIR"; rc=1; }
grep -q 'draft_file="\$TMP_DIR/scaletta-\$kind\.draft\.md"' "$S" \
  || { echo "FAIL: the draft is not written to TMP_DIR"; rc=1; }
grep -q 'OUT_DIR/[^"]*draft' "$S" && { echo "FAIL: a draft is still written into OUT_DIR"; rc=1; }
# Sub-bullets are plain dots: the prompt forbids letters and the writer strips them.
grep -q 'non etichettarli' "$S" || { echo "FAIL: prompts do not forbid lettered sub-bullets"; rc=1; }
grep -q '\[a-z\]\\)' "$S" || { echo "FAIL: strip_and_write does not remove (a)/(b)/(c) labels"; rc=1; }
[ -f ./lint_scaletta.py ] || { echo "FAIL: lint_scaletta.py missing"; rc=1; }
grep -qi 'humaniz' ../SKILL.md || { echo "FAIL: SKILL.md has no humanize step"; rc=1; }
grep -q 'lint_scaletta' ../SKILL.md || { echo "FAIL: SKILL.md does not call the lint"; rc=1; }
grep -q -- '--brief' "$S" && { echo "FAIL: --brief should be gone"; rc=1; }
grep -q 'short_atom' "$S" && { echo "FAIL: short_atom should be gone"; rc=1; }
grep -q 'BRIEF_FILE' "$S" && { echo "FAIL: BRIEF_FILE should be gone"; rc=1; }
grep -q 'termini\.md' "$S" && { echo "FAIL: termini.md should no longer be written"; rc=1; }
grep -q 'TERMINI_PROMPT\|gen_termini' "$S" && { echo "FAIL: the Termini ask should be gone"; rc=1; }
grep -q -- '--draft' "$S" || { echo "FAIL: lint is not run in draft-comparison mode"; rc=1; }
grep -q 'finish_scaletta' "$S" || { echo "FAIL: no finish_scaletta step"; rc=1; }
grep -q 'lint_scaletta.py' "$S" || { echo "FAIL: lint is not called from the script"; rc=1; }
grep -qi 'mandatory\|manual' ../SKILL.md && grep -qi 'invoke the .humanizer. skill' ../SKILL.md \
  && { echo "FAIL: SKILL.md still describes the manual humanize step"; rc=1; }
[ -f ./humanize.test.sh ] || { echo "FAIL: humanize.test.sh missing"; rc=1; }
grep -v '^[[:space:]]*#' "$S" | grep -q 'notebooklm doctor' \
  && { echo "FAIL: auth gate relies on doctor, which passes on a dead session"; rc=1; }
grep -q 'notebooklm login --fresh' "$S" || { echo "FAIL: auth failure does not name the login command"; rc=1; }
grep -q 'gen_images\|images_preflight\|NBLM_PYTHON\|IMAGES_\|CONCEPTS_PROMPT' "$S" \
  && { echo "FAIL: infographic machinery should be gone"; rc=1; }
grep -q -- '--images-only\|--script-only' "$S" && { echo "FAIL: image mode flags should be gone"; rc=1; }
grep -q 'KIND' "$S" && { echo "FAIL: KIND mode should be gone -- there is only one output now"; rc=1; }
[ -e ../../social-notebooklm-artifacts ] && { echo "FAIL: the old skill directory should be deleted"; rc=1; }
[ -f ./lint_scaletta.py ] || { echo "FAIL: lint did not move into this skill"; rc=1; }
# Both prompts must ask for the same layout: bold section headings on their own
# line. editor_script.py has one split rule, and a short Scaletta that drifts
# back to inline bullets would silently produce zero Scenes.
short=$(grep -m1 '^SHORT_PROMPT=' "$S")
printf '%s' "$short" | grep -q 'titolo breve in grassetto' \
  || { echo "FAIL: SHORT_PROMPT does not ask for bold section headings"; rc=1; }
# -i: the prompt shouts this clause (SU UNA RIGA TUTTA SUA) for emphasis, and
# whether it is shouted is not what the assertion is about.
printf '%s' "$short" | grep -qi 'su una riga tutta sua' \
  || { echo "FAIL: SHORT_PROMPT does not require the heading on its own line"; rc=1; }
printf '%s' "$short" | grep -q '1 bullet HOOK' \
  && { echo "FAIL: SHORT_PROMPT still asks for the inline-bullet layout"; rc=1; }

# The Editor stage is chained, and non-fatal: a closed Editor must never cost a
# Scaletta that was already written and linted.
grep -q 'editor-script.sh' "$S" || { echo "FAIL: scaletta.sh does not chain the editor stage"; rc=1; }
grep -q 'HERE_SCRIPTS/editor-script.sh' "$S" \
  || { echo "FAIL: the editor stage is not resolved beside scaletta.sh"; rc=1; }
grep -qE 'editor-script\.sh".*\|\||push_editor' "$S" \
  || { echo "FAIL: the editor stage looks fatal, not guarded"; rc=1; }
grep -q 'NO_EDITOR' "$S" || { echo "FAIL: no opt-out from the editor stage"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: scaletta.sh config"
exit "$rc"
