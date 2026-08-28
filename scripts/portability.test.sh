#!/usr/bin/env bash
# Repo-wide sweep: a skill must not carry the machine it was written on.
# Run: bash scripts/portability.test.sh
#
# Every check here was a real bug once — an absolute path in a README's
# copy-paste block, `brew install` handed to a Debian reader, a settings file
# written to a directory the agent does not read. All are cheap to reintroduce
# and invisible until someone else clones the repo.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# Findings in, verdict out. Takes the hits as an argument rather than on stdin:
# a pipeline would run this in a subshell and the pass/fail counters would be
# incremented in a process that then exits.
report() {  # <label> <hits>
  local label="$1" hits
  hits=$(printf '%s' "$2" | grep -v 'portability-ok') || true
  [ -z "$hits" ] && ok "$label" || bad "$label" "$hits"
}

# graphify-out is a generated cache; every path in it is absolute by design.
# `._*` are macOS AppleDouble sidecars from the external drive: binary, and they
# match *.sh and *.md, so a sweep that reads them is reading noise.
ALL=(--include='*.sh' --include='*.md' --include='*.py' --include='*.js'
     --include='*.json' --exclude='._*' --exclude-dir=graphify-out
     skills/ scripts/ config/)
SH=(--include='*.sh' --exclude='._*' --exclude-dir=graphify-out skills/ scripts/)
# A comment naming a conventional path is documentation, not a hardcoded path.
NOT_COMMENT='^[^:]+:[0-9]+:[[:space:]]*#'

echo "no path names this machine"
# The patterns are derived from THIS machine, never written down. A literal
# home path would catch exactly one author, read as noise to everyone else, and
# trip this very file. Asking $HOME and $PWD makes the check work unchanged for
# whoever clones the repo next.
#
# Deliberately narrow, and comments are NOT exempt here: `/Users/x` in a
# fixture and `/Users/<you>` in a prose example are both fine and neither
# matches, but the author's real home path is a leak wherever it appears.
for pat in "/Users/$(basename "$HOME")" "/home/$(basename "$HOME")" "$(pwd -P)"; do
  report "no '$pat'" "$(grep -rnF "$pat" "${ALL[@]}" 2>/dev/null)"
done

echo "no hardcoded package manager"
# `brew install` is right only where the manager was actually detected.
# Everywhere else it is advice a Linux reader cannot follow, so it routes
# through iso_pkg_install — which lives in lib/config.sh, hence the exemption.
report "installs route through iso_pkg_install" \
  "$(grep -rnE '\b(brew|apt-get|dnf|pacman|apk) (install|add|-S)\b' "${SH[@]}" 2>/dev/null \
     | grep -vE "$NOT_COMMENT" | grep -v 'iso-config/scripts/lib/config.sh')"

echo "agent config dirs are overridable"
# Claude Code honours CLAUDE_CONFIG_DIR, Codex honours CODEX_HOME. A bare
# $HOME/.claude ignores a user who moved theirs, and fails silently: the file
# is written, just not where the agent reads it.
#
# Two files are exempt wholesale, each for a stated reason at the site:
# lib/config.sh holds tildified DEFAULTS every consumer may override, and
# iso-spawn/tests/run.sh is the fixture that asserts tilde expansion itself.
report "agent config dir must be overridable" \
  "$(grep -rnE '(\$HOME|~)/\.(claude|codex)' "${SH[@]}" 2>/dev/null \
     | grep -vE "$NOT_COMMENT" \
     | grep -v 'CLAUDE_CONFIG_DIR\|CODEX_HOME' \
     | grep -vE 'iso-config/scripts/lib/config.sh|iso-spawn/tests/run.sh')"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
