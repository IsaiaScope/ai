#!/usr/bin/env bash
# Every reference to a repo-owned skill names a skill that exists on disk.
#
# A rename moves a directory and rewrites the prose pointing at it. The rewrite
# is a search-and-replace, so it only finds what it searched for -- and the
# check that the rename is complete is usually that same search, which makes the
# check exactly as blind as the edit. The iso-refine -> iso-review rename
# reported clean while README.md still said "iso<U+2011>refine" twice, because
# the sweep and its verification both grepped an ASCII hyphen and the skills
# table used a non-breaking one.
#
# So this asks the filesystem instead of the search term: collect every name a
# live file points at, require a directory for each. A typo, a half-finished
# rename and a deleted skill all fail the same way.
#
# ponytail: repo-owned families only (iso-, hetzner-, social-). `/review` and
# `/simplify` are other people's skills with no directory here to check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"
        if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi; }

FAMILIES='iso|hetzner|social'

# Excluded, and why:
#   docs/superpowers/  dated plans and specs -- a superseded name is history
#   docs/adr/          decision records naming skills that were deleted BY that
#                      decision; a dangling name there is the record working
#   graphify-out/      generated knowledge-graph snapshots, not prose
live_files() {
  find . -type f \( -name '*.md' -o -name '*.json' \) \
    ! -path './.git/*' \
    ! -path './docs/superpowers/*' \
    ! -path './docs/adr/*' \
    ! -path './graphify-out/*' \
    ! -path './node_modules/*' \
    ! -name '._*'
}

# One matcher, used by the sweep AND by the probes below. Spelling it three
# times meant the probes asserted against their own private copies: tighten the
# sweep, forget a probe, and the "a check that cannot fail is not a check"
# guard becomes a check that cannot fail.
#
# fold() does two jobs in one process:
#   - U+2010 / U+2011 / U+2013 all render as a hyphen and all defeat an ASCII
#     grep. Folding them at read time IS this guard's reason to exist -- the
#     rename that shipped broken had `iso<U+2011>refine` in README.
#   - drops lines carrying `skill-refs-ok`, the same escape hatch the
#     portability sweep spells `portability-ok`.
fold() {
  sed -e '/skill-refs-ok/d' \
      -e 's/\xe2\x80\x90/-/g' -e 's/\xe2\x80\x91/-/g' -e 's/\xe2\x80\x93/-/g'
}

# Reference-SHAPED names only: a `skills/<name>` path, a `/<name>` slash
# command, or a `<name>` in backticks. Bare prose is not a reference ("five
# social-video titles"), nor is a template placeholder (`<iso-timestamp>`), nor
# a filesystem path (/var/lib/cloud/hetzner-create-done) -- hence the leading
# non-path delimiter. Display text outside those three shapes is missed on
# purpose: README carried BOTH `iso<U+2011>refine` as link text and
# `/iso<U+2011>refine` as a command, and catching either is enough to stop a
# run and send a human to look.
ref_names() {
  grep -oE "(^|[^A-Za-z0-9_/-])(skills/|/|\`)($FAMILIES)-[a-z0-9-]+" \
    | sed -E "s#^[^A-Za-z0-9_]*##; s#^skills/##"
}

refs=$(live_files | while IFS= read -r f; do
  fold < "$f" | ref_names \
    | while IFS= read -r name; do printf '%s\t%s\n' "$name" "${f#./}"; done
done | sort -u)

if [ -z "$refs" ]; then
  bad "no skill references found at all - sweep is not looking where it thinks"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

names=$(printf '%s\n' "$refs" | cut -f1 | sort -u)
n_names=$(printf '%s\n' "$names" | grep -c .)
missing=0
for name in $names; do
  [ -d "skills/$name" ] && continue
  missing=1
  where=$(printf '%s\n' "$refs" | awk -F'\t' -v n="$name" '$1==n {print $2}' | sort -u | tr '\n' ' ')
  bad "no skills/$name/ on disk, referenced by: $where"
done
[ "$missing" -eq 0 ] && ok "all $n_names referenced skill name(s) exist on disk"

# A check that cannot fail is not a check. Prove the fold still sees a
# non-ASCII hyphen, and that a mid-path name is still rejected.
# $'...' so bash expands the escapes -- plain single quotes pass the literal
# backslashes through and the probe silently tests nothing.
for cp in "U+2010:"$'\xe2\x80\x90' "U+2011:"$'\xe2\x80\x91' "U+2013:"$'\xe2\x80\x93'; do
  probe=$(printf '`/iso%sreview`\n' "${cp#*:}" | fold | ref_names | head -1)
  [ "$probe" = "iso-review" ] \
    && ok "hyphen fold handles ${cp%%:*}" \
    || bad "fold broken for ${cp%%:*}" "got '$probe'"
done

for junk in '/var/lib/cloud/hetzner-create-done' 'five social-video titles' '<iso-timestamp>'; do
  hit=$(printf '%s\n' "$junk" | fold | ref_names)
  [ -z "$hit" ] \
    && ok "not a reference: $junk" \
    || bad "false positive on '$junk'" "matched '$hit'"
done

marked=$(printf '`/iso-rebase` <!-- skill-refs-ok -->\n' | fold | ref_names)
[ -z "$marked" ] \
  && ok "skill-refs-ok marker exempts a line" \
  || bad "skill-refs-ok marker not honoured" "matched '$marked'"

[ "$n_names" -ge 8 ] \
  && ok "swept $n_names distinct skill name(s)" \
  || bad "only $n_names distinct skill name(s) seen - sweep is not looking where it thinks"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
