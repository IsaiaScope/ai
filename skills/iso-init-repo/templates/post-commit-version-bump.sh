#!/usr/bin/env bash
#
# Post-commit: auto-bump root package.json version, then amend into the same commit.
# Conventional Commits: feat!|BREAKING CHANGE → major, feat → minor, else → patch.
# Skips merge commits. Guards against re-trigger via .git/VERSION_BUMP_RUNNING.

GUARD="$(git rev-parse --git-dir)/VERSION_BUMP_RUNNING"
[ -f "$GUARD" ] && exit 0

COMMIT_MSG=$(git log -1 --format=%B HEAD)

# Skip merge commits
echo "$COMMIT_MSG" | grep -qE '^Merge ' && exit 0

# Detect bump level (major check first — feat! must not fall through to minor)
if echo "$COMMIT_MSG" | grep -qE '^[a-z]+(\(.+\))?!:|^BREAKING CHANGE:'; then
  BUMP="major"
elif echo "$COMMIT_MSG" | grep -qE '^feat(\(.+\))?:'; then
  BUMP="minor"
else
  BUMP="patch"
fi

# Detect package manager + lock file
if [ -f pnpm-lock.yaml ]; then
  PM="pnpm"; LOCK="pnpm-lock.yaml"
elif [ -f yarn.lock ]; then
  PM="yarn"; LOCK="yarn.lock"
elif [ -f bun.lockb ]; then
  PM="bun"; LOCK="bun.lockb"
elif [ -f bun.lock ]; then
  PM="bun"; LOCK="bun.lock"
else
  PM="npm"; LOCK="package-lock.json"
fi

trap 'rm -f "$GUARD"' EXIT
touch "$GUARD"

$PM version "$BUMP" --no-git-tag-version >/dev/null
git add package.json "$LOCK" 2>/dev/null
git commit --amend --no-edit --no-verify
