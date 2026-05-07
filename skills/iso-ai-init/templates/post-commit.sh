#!/bin/sh
# graphify-hook-start
# Auto-rebuilds graphify knowledge graph after each commit (code AST only, no LLM).
# Skip during rebase/merge/cherry-pick to avoid blocking --continue.
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
[ -d "$GIT_DIR/rebase-merge" ] && exit 0
[ -d "$GIT_DIR/rebase-apply" ] && exit 0
[ -f "$GIT_DIR/MERGE_HEAD" ] && exit 0
[ -f "$GIT_DIR/CHERRY_PICK_HEAD" ] && exit 0

if ! command -v graphify >/dev/null 2>&1; then
    exit 0
fi

CHANGED=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD 2>/dev/null)
[ -z "$CHANGED" ] && exit 0

_GRAPHIFY_LOG="${HOME}/.cache/graphify-rebuild.log"
mkdir -p "$(dirname "$_GRAPHIFY_LOG")"
nohup graphify update . > "$_GRAPHIFY_LOG" 2>&1 < /dev/null &
disown 2>/dev/null || true
# graphify-hook-end
