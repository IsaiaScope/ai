#!/usr/bin/env bash
# Self-check for config.sh. Run: bash config.test.sh
# ponytail: asserts only on the merge and on defaults — the two places a wrong
# answer silently redirects work to the wrong branch or the wrong board.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/config.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

# shellcheck source=/dev/null
. "$LIB"
type iso_config_get >/dev/null 2>&1 || { echo "FATAL: sourcing did not define iso_config_get"; exit 1; }

tmp=$(mktemp -d)
export ISO_GLOBAL_CONFIG="$tmp/absent.json"

echo "defaults"
cd "$tmp" || exit 1
check "development default"  "$(iso_config_get branches.development)" "dev"
check "plans path default"   "$(iso_config_get paths.plans)"          "docs/superpowers/plans"
check "tracker default"      "$(iso_config_get tracker.kind)"         "multica"
check "array joins on space" "$(iso_config_get branches.protected)"   "dev develop test prod main master"
check "unknown key is empty" "$(iso_config_get branches.nope)"        ""

echo "global scope"
ISO_GLOBAL_CONFIG="$tmp/global.json"
printf '%s\n' '{"terminal":{"kind":"tmux"}}' > "$ISO_GLOBAL_CONFIG"
check "global overrides default"    "$(iso_config_get terminal.kind)"        "tmux"
check "unmentioned key survives"    "$(iso_config_get branches.development)" "dev"

echo "repo overlay"
repo="$tmp/repo"; mkdir -p "$repo/docs/iso"
( cd "$repo" && git init -q -b main . )
printf '%s\n' '{"branches":{"default":"prod"}}' > "$repo/docs/iso/config.json"
cd "$repo" || exit 1
check "overlay overrides global"    "$(iso_config_get branches.default)"     "prod"
check "sibling key survives merge"  "$(iso_config_get branches.pr_base)"     "dev"
check "other sections survive"      "$(iso_config_get tracker.kind)"         "multica"

echo "overlay validation"
printf '%s\n' '{"branches":{"defualt":"prod"}}' > "$repo/docs/iso/config.json"
err=$(iso_config_validate_overlay "$repo/docs/iso/config.json" 2>&1); rc=$?
check "typo rejected"        "$rc" "1"
case "$err" in *defualt*) ok "names the bad key";; *) bad "names the bad key";; esac

printf '%s\n' '{"tracker":{"kind":"github"}}' > "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "forbidden section rejected" "$?" "1"

printf '%s\n' '{"branches":{"default":"prod"},"paths":{"plans":"p"}}' > "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "valid overlay accepted" "$?" "0"

rm -f "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "absent overlay is valid" "$?" "0"

echo "readiness stamp"
cd "$tmp" || exit 1
ISO_GLOBAL_CONFIG="$tmp/stamp.json"; rm -f "$ISO_GLOBAL_CONFIG"
ISO_PREREQ_VERSION=1
iso_stamp_ok; check "no config -> not ok" "$?" "1"

iso_stamp_write
iso_stamp_ok; check "after write -> ok" "$?" "0"
[ -n "$(iso_config_get checked.at)" ] && ok "stamp records a time" || bad "stamp records a time"
check "stamp records version" "$(iso_config_get checked.version)" "1"

ISO_PREREQ_VERSION=2
iso_stamp_ok; check "version bump invalidates" "$?" "1"
ISO_PREREQ_VERSION=1

echo "doctor: hook check"
CFG="${LIB%/lib/config.sh}/config.sh"   # $LIB is absolute; an earlier test may have cd'd away
HD=$(mktemp -d)

# No settings file at all: say so, do not fail readiness.
out=$(ISO_AGENT_SETTINGS="$HD/absent.json" bash -c '. "'"$CFG"'"; cmd_doctor_hooks' 2>/dev/null) || true
case "$out" in *absent*) ok "a missing settings file is reported, not fatal" ;;
  *) bad "missing settings file not reported" ;; esac

# A marked hook whose target is executable is ok.
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"command":"S=\"'"$HD"'/t.sh\"; [ -x \"$S\" ] && \"$S\" reconcile; exit 0  # iso-hook:reconcile"}]}]}}' > "$HD/live.json"
printf '#!/bin/sh\n' > "$HD/t.sh"; chmod +x "$HD/t.sh"
out=$(ISO_AGENT_SETTINGS="$HD/live.json" bash -c '. "'"$CFG"'"; cmd_doctor_hooks' 2>/dev/null)
case "$out" in *"ok       hook SessionStart/reconcile"*) ok "a live hook reads ok" ;;
  *) bad "live hook not recognised: $out" ;; esac
# The end hook is absent from that file and must be called out by name.
case "$out" in *"MISSING  hook SessionEnd/end"*) ok "an absent hook is named" ;;
  *) bad "absent hook not named" ;; esac

# The bug this exists for: the marker is present, the target is not. Matching on
# the path would have reported nothing at all here.
chmod -x "$HD/t.sh"
out=$(ISO_AGENT_SETTINGS="$HD/live.json" bash -c '. "'"$CFG"'"; cmd_doctor_hooks' 2>/dev/null)
case "$out" in *"STALE    hook SessionStart/reconcile"*) ok "a hook pointing at a dead path is STALE" ;;
  *) bad "stale hook not detected: $out" ;; esac
case "$out" in *"node scripts/install.js"*) ok "the remedy names install.js" ;;
  *) bad "no remedy printed" ;; esac
# The list doctor iterates and the list install.js writes must be one file, or
# doctor can report ready while checking fewer hooks than exist.
HOOKS_JSON="${LIB%/iso-config/scripts/lib/config.sh}/iso-tracking/scripts/hooks.json"
if [ -f "$HOOKS_JSON" ]; then
  want=$(jq -r '.[] | "\(.event):\(.name)"' "$HOOKS_JSON")
  got=$(bash -c '. "'"$CFG"'"; iso_hooks')
  check "doctor iterates the shared hooks.json, not a second list" "$got" "$want"
  check "every hook entry carries name, event and verb" \
    "$(jq '[.[] | select((.name|type=="string") and (.event|type=="string") and (.verb|type=="string"))] | length == length' "$HOOKS_JSON")" "true"
else
  bad "hooks.json missing at $HOOKS_JSON"
fi

rm -rf "$HD"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
