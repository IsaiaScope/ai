#!/usr/bin/env bash
# iso-commit mechanics: preflight, secret guard, staging, commit.
# Message authoring lives in SKILL.md — this script never writes prose.
set -euo pipefail

die() { printf 'iso-commit: %s\n' "$1" >&2; exit 1; }

# Files that must never be swept in by `git add -A`.
# ponytail: filename patterns only — no content scanning. Catches the common
# accident (committing a real .env / private key), not a determined mistake.
SECRET_RE='(^|/)\.env(\.local|\.production|\.development)?$|\.pem$|\.key$|\.p12$|\.pfx$|\.jks$|\.keystore$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)\.npmrc$|(^|/)\.netrc$|(^|/)credentials\.json$|(^|/)\.aws/credentials$|(^|/)secrets?\.(ya?ml|json|toml)$'
SECRET_ALLOW_RE='\.(example|sample|template|dist)$|\.env\.example'

# ---------------------------------------------------------------- preflight
# Repo? On a branch (not detached)? Anything to commit?
cmd_preflight() {
  git rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git repository"

  # symbolic-ref resolves an unborn branch (fresh repo, no commits yet) and
  # fails on detached HEAD — exactly the split we want. rev-parse can't do both.
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || die "detached HEAD — check out a branch before committing"

  local mode="${1:---all}"
  if [ "$mode" = "--staged" ]; then
    git diff --cached --quiet && die "nothing staged (--staged mode)"
  else
    [ -n "$(git status --porcelain)" ] || die "working tree clean — nothing to commit"
  fi

  printf '%s\n' "$branch"
}

# ------------------------------------------------------------------- candidates
# Files this run would commit, one per line. Read before staging so the guard
# can abort while the index is still untouched.
cmd_candidates() {
  local mode="${1:---all}"
  if [ "$mode" = "--staged" ]; then
    git diff --cached --name-only
  else
    { git status --porcelain --untracked-files=all | sed 's/^...//'; } | sed 's/.* -> //'
  fi
}

# ----------------------------------------------------------------------- guard
# Abort if any candidate looks like a credential. Exit 2 = blocked.
cmd_guard() {
  local mode="${1:---all}" hits
  hits=$(cmd_candidates "$mode" | grep -Ev "$SECRET_ALLOW_RE" | grep -E "$SECRET_RE" || true)
  if [ -n "$hits" ]; then
    printf 'iso-commit: refusing to commit — these look like credentials:\n' >&2
    printf '  %s\n' $hits >&2
    printf '\nGitignore them, or stage the rest yourself and re-run with --staged.\n' >&2
    exit 2
  fi
}

# ----------------------------------------------------------------------- stage
cmd_stage() {
  local mode="${1:---all}"
  cmd_guard "$mode"
  [ "$mode" = "--staged" ] || git add -A
  git diff --cached --quiet && die "nothing staged after add"
  git diff --cached --name-only
}

# ---------------------------------------------------------------------- commit
# Message comes from a file so multi-line bodies survive verbatim.
# Hooks run on purpose: commitlint must gate the subject, version-bump must fire.
cmd_commit() {
  local msgfile="${1:-}"
  [ -n "$msgfile" ] && [ -f "$msgfile" ] || die "usage: commit.sh commit <message-file>"
  [ -s "$msgfile" ] || die "message file is empty"
  git commit -F "$msgfile"
  git --no-pager log -1 --format='%h %s'
}

case "${1:-}" in
  preflight)  shift; cmd_preflight "$@" ;;
  candidates) shift; cmd_candidates "$@" ;;
  guard)      shift; cmd_guard "$@" ;;
  stage)      shift; cmd_stage "$@" ;;
  commit)     shift; cmd_commit "$@" ;;
  *) die "usage: commit.sh {preflight|candidates|guard|stage|commit} [--staged|<msgfile>]" ;;
esac
