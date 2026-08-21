#!/usr/bin/env bash
# Self-check for sibling.sh. Run: bash sibling.test.sh
# Builds each of the four real install topologies in a temp dir and resolves
# across them. The bug this guards is silent: a wrong path just means tracking
# quietly stops happening.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)/sibling.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

tmp=$(mktemp -d)

# A skills root with two skills: one that calls, one that is called.
mkskills() {
  local root="$1"
  mkdir -p "$root/iso-caller/scripts" "$root/iso-target/scripts"
  cp "$LIB" "$root/iso-caller/scripts/sibling.sh"
  printf '#!/bin/sh\necho reached\n' > "$root/iso-target/scripts/run.sh"
  chmod +x "$root/iso-target/scripts/run.sh"
  cat > "$root/iso-caller/scripts/call.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/sibling.sh"
iso_sibling iso-target scripts/run.sh
SH
  chmod +x "$root/iso-caller/scripts/call.sh"
}

echo "topology: repository"
mkskills "$tmp/repo/skills"
check "resolves in repo" \
  "$(bash "$tmp/repo/skills/iso-caller/scripts/call.sh")" \
  "$tmp/repo/skills/iso-target/scripts/run.sh"

echo "topology: development symlink"
mkdir -p "$tmp/home/.claude/skills"
ln -sfn "$tmp/repo/skills/iso-caller" "$tmp/home/.claude/skills/iso-caller"
ln -sfn "$tmp/repo/skills/iso-target" "$tmp/home/.claude/skills/iso-target"
out=$(bash "$tmp/home/.claude/skills/iso-caller/scripts/call.sh")
[ -f "$out" ] && ok "resolves through symlink" || { bad "resolves through symlink"; printf '       got=%q\n' "$out"; }

echo "topology: marketplace clone"
mkskills "$tmp/marketplaces/marketonfire/skills"
check "resolves in clone" \
  "$(bash "$tmp/marketplaces/marketonfire/skills/iso-caller/scripts/call.sh")" \
  "$tmp/marketplaces/marketonfire/skills/iso-target/scripts/run.sh"

echo "topology: .agents indirection"
mkskills "$tmp/agents/skills"
check "resolves in .agents" \
  "$(bash "$tmp/agents/skills/iso-caller/scripts/call.sh")" \
  "$tmp/agents/skills/iso-target/scripts/run.sh"

echo "missing target"
bash -c ". $LIB; iso_sibling iso-nope scripts/run.sh" >/dev/null 2>&1
check "absent sibling -> rc 1" "$?" "1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
