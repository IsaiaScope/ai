#!/usr/bin/env bash
# Write a Content's Scalette into the video Editor as Scenes.
#
# Two Editor Projects per Content, because canvas format is a Project-level
# property: one horizontal for the long video, one vertical for the Short.
#
# DESTRUCTIVE. Re-running replaces a Project's Scenes and destroys any Takes
# recorded against them. See docs/adr/0002-editor-scenes-replace-destructively.md
# in the content repository.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=both
CONTENT_DIR=""

usage() {
  echo "usage: editor-script.sh <content-dir> [--long|--short]" >&2
  echo "  --long|--short   push only one length (default: both)" >&2
}

die() { printf 'editor-script: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --long)  MODE=long; shift ;;
    --short) MODE=short; shift ;;
    -h|--help) usage; exit 1 ;;
    -*) die "unknown flag: $1" ;;
    *)  CONTENT_DIR="$1"; shift ;;
  esac
done

[ -n "$CONTENT_DIR" ] || { usage; exit 1; }
[ -d "$CONTENT_DIR" ] || die "no such Content directory: $CONTENT_DIR"

# Config, with an env override so the test can substitute a stub. Resolved
# through iso_sibling rather than $HOME/.claude: that path is correct under one
# of the four install topologies and silently wrong under the rest.
EDITOR_BIN="${SOCIAL_EDITOR_BIN:-}"
EDITOR_KIND="${SOCIAL_EDITOR_KIND:-}"
if [ -z "$EDITOR_BIN" ] || [ -z "$EDITOR_KIND" ]; then
  if lib=$( . "$HERE/../../iso-config/scripts/lib/sibling.sh" 2>/dev/null && \
            iso_sibling iso-config scripts/lib/config.sh ); then
    # shellcheck disable=SC1090
    . "$lib"
    [ -n "$EDITOR_BIN" ]  || EDITOR_BIN=$(iso_config_get editor.bin)
    [ -n "$EDITOR_KIND" ] || EDITOR_KIND=$(iso_config_get editor.kind)
  fi
fi
[ -n "$EDITOR_BIN" ] || die "no editor configured -- set editor.bin in ~/.config/iso/iso.json, or SOCIAL_EDITOR_BIN"

# The tool names sent over the wire are Borumi's. A second editor must fail
# here, naming itself, rather than have Borumi's vocabulary sent to something
# that does not speak it.
case "${EDITOR_KIND:-borumi}" in
  borumi) : ;;
  *) die "editor.kind is '${EDITOR_KIND}', but only 'borumi' is implemented" ;;
esac

# The Project name is the Content folder whole and unparsed. Not the title
# alone: " - " also occurs inside titles, and the date is what keeps two
# Contents sharing a title from overwriting each other's recordings.
FOLDER=$(basename "$CONTENT_DIR")
TIMEOUT="${EDITOR_TIMEOUT:-60}"
rc=0

push_one() {
  local kind="$1" preset="$2" file="$CONTENT_DIR/scaletta-$1.md"
  # A length that was never generated is skipped, not fatal: `scaletta.sh
  # --long` legitimately leaves no short Scaletta behind.
  [ -f "$file" ] || { printf '  skip   no scaletta-%s.md\n' "$kind" >&2; return 0; }
  if python3 "$HERE/editor_script.py" "$file" \
       --binary "$EDITOR_BIN" --name "$FOLDER - $kind" \
       --preset "$preset" --timeout "$TIMEOUT"; then
    printf '  ok     %s - %s\n' "$FOLDER" "$kind" >&2
  else
    printf '  warn   %s - %s failed\n' "$FOLDER" "$kind" >&2
    return 1
  fi
}

# The two Projects are independent: a failure on one is reported and the other
# still runs, so a broken long Scaletta never costs you the Short.
case "$MODE" in
  long)  push_one long  landscape || rc=1 ;;
  short) push_one short vertical  || rc=1 ;;
  both)  push_one long  landscape || rc=1
         push_one short vertical  || rc=1 ;;
esac

exit "$rc"
