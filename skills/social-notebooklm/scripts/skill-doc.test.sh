#!/usr/bin/env bash
# SKILL.md documents the native path and no longer promises Codex research.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
S=../SKILL.md
grep -qi 'codex-agent deep research' "$S" && { echo "FAIL: still documents Codex-agent research"; rc=1; }
grep -qi 'bounded' "$S" && { echo "FAIL: --bounded should be gone (replaced by --fast)"; rc=1; }
grep -q 'add-research' "$S" || { echo "FAIL: does not document native deep research"; rc=1; }
grep -q 'scripts/notebook.sh' "$S" || { echo "FAIL: does not point at notebook.sh"; rc=1; }
grep -q -- '--timeout 1800' "$S" && { echo "FAIL: still documents the old 1800s cap"; rc=1; }
grep -q 'RESEARCH_TIMEOUT' "$S" || { echo "FAIL: does not document the wait budget override"; rc=1; }
grep -q '86400' "$S" || { echo "FAIL: does not record the uncapped default"; rc=1; }
grep -qi 'title' "$S" && grep -q -- '--title' "$S" || { echo "FAIL: does not document title suggestions"; rc=1; }
grep -q -- '--save-as-note' "$S" || { echo "FAIL: does not say suggestions are saved to the notebook"; rc=1; }
head -5 "$S" | grep -qi 'youtube' || { echo "FAIL: frontmatter does not mention mixed URL input"; rc=1; }
DOC=../SKILL.md
grep -q 'editor-script' "$DOC" || { echo "FAIL: SKILL.md never mentions the editor stage"; rc=1; }
grep -qi 'delete_recordings' "$DOC" || { echo "FAIL: SKILL.md does not warn that re-runs destroy recordings"; rc=1; }
grep -q 'editor.bin' "$DOC" || { echo "FAIL: SKILL.md does not say where the editor is configured"; rc=1; }
grep -q 'NO_EDITOR' "$DOC" || { echo "FAIL: SKILL.md does not document the opt-out"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: skill doc"
exit "$rc"
