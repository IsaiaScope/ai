#!/usr/bin/env bash
# Iso config: the merged view of the global and repo scopes.
# Sourced, never executed — so it sets no shell options of its own.
# ponytail: jq does the merge. `*` is a deep object merge, which is exactly
# per-key semantics; arrays replace wholesale, which is right for `protected`.

ISO_GLOBAL_CONFIG="${ISO_GLOBAL_CONFIG:-$HOME/.config/iso/iso.json}"

# Every read below goes through jq, and this library is the first thing any
# skill sources. Check here so a missing jq is one sentence, not
# `jq: command not found` surfacing from the middle of an unrelated skill.
command -v jq >/dev/null 2>&1 || {
  printf 'iso-config: jq is required -- brew install jq\n' >&2
  return 1 2>/dev/null || exit 1
}

# Today's hardcoded values, so a machine with no config behaves as it does now.
# branches.default is null on purpose: it FOLLOWS branches.development unless a
# scope sets it. A concrete "dev" here would mean renaming the development
# branch silently left GitHub's default pointing at a branch that no longer
# exists.
iso_defaults() {
  cat <<'JSON'
{
  "branches": {
    "development": "dev",
    "test": "test",
    "production": "prod",
    "default": null,
    "pr_base": "dev",
    "protected": ["dev", "develop", "test", "prod", "main", "master"]
  },
  "paths": {
    "plans": "docs/superpowers/plans",
    "specs": "docs/superpowers/specs",
    "artifacts": "docs/iso/logs"
  },
  "tracker":  { "kind": "multica", "ledger": "~/.claude/multica" },
  "terminal": { "kind": "herdr" },
  "identity": { "org": "IsaiaScope", "marketplace": "marketonfire" },
  "agents": {
    "codex":  { "sessions": "~/.codex/sessions",  "full_access": "--dangerously-bypass-approvals-and-sandbox" },
    "claude": { "sessions": "~/.claude/projects", "full_access": "--dangerously-skip-permissions" }
  },
  "checked": { "at": null, "version": 0 }
}
JSON
}

iso_repo_overlay_path() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s/docs/iso/config.json' "$root"
}

_iso_json_or_empty() { [ -f "$1" ] && printf '%s' "$(<"$1")" || printf '{}'; }

# The overlay describes a repository, so it may name only what is a property of
# one. Letting it set `tracker` or `identity` would mean cloning somebody's
# repository silently redirects where your work gets filed.
ISO_OVERLAY_KEYS='branches.development branches.test branches.production
branches.default branches.pr_base branches.protected
paths.plans paths.specs paths.artifacts'

iso_config_validate_overlay() {
  local f="$1" found bad
  [ -f "$f" ] || return 0
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
    || { printf 'iso-config: %s is not a JSON object\n' "$f" >&2; return 1; }
  found=$(jq -r '
    to_entries[]
    | .key as $s
    | if (.value | type) == "object" then (.value | keys[] | "\($s).\(.)")
      else $s end' "$f" 2>/dev/null)
  bad=$(comm -23 <(printf '%s\n' "$found" | sort -u) \
                 <(printf '%s\n' $ISO_OVERLAY_KEYS | sort -u))
  [ -z "$bad" ] && return 0
  printf 'iso-config: unknown key %s in %s\n' $bad "$f" >&2
  return 1
}

# The merge is four processes, and a caller that reads five keys would pay for
# it five times. Memoized per scope pair: a script reading the whole vocabulary
# now spawns jq once instead of twenty times.
_ISO_CONFIG_KEY=""
_ISO_CONFIG_CACHE=""

# Drop the memo. Anything that WRITES a scope file in-process must call this —
# the key is the pair of paths, so same-path-new-content would otherwise serve
# the old document.
iso_config_flush() { _ISO_CONFIG_KEY=""; _ISO_CONFIG_CACHE=""; }

iso_config() {
  local overlay="" key
  overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  iso_config_validate_overlay "$overlay" || return 1
  key="$ISO_GLOBAL_CONFIG|$overlay"
  if [ "$key" != "$_ISO_CONFIG_KEY" ]; then
    _ISO_CONFIG_CACHE=$(jq -s '.[0] * .[1] * .[2]' \
      <(iso_defaults) \
      <(_iso_json_or_empty "$ISO_GLOBAL_CONFIG") \
      <(_iso_json_or_empty "$overlay")) || return 1
    _ISO_CONFIG_KEY="$key"
  fi
  printf '%s\n' "$_ISO_CONFIG_CACHE"
}

# Dotted key -> string. Arrays join on a space so callers can `for x in $(...)`.
# Unset reads as empty, never as the literal "null".
iso_config_get() {
  iso_config | jq -r --arg k "$1" '
    reduce ($k | split(".")[]) as $p (.;
      if type == "object" then .[$p] else null end)
    | if   type == "array"  then join(" ")
      elif . == null        then ""
      else tostring end'
}

# The stamp says the sweep passed, and against which prerequisite list. Skills
# trust it rather than re-probing the filesystem on every invocation.
# ponytail: no per-binary path recording — a version bump is the invalidation
# lever, and it is the one that survives the skills being edited.
iso_stamp_write() {
  local now dir
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dir=$(dirname "$ISO_GLOBAL_CONFIG"); mkdir -p "$dir"
  [ -f "$ISO_GLOBAL_CONFIG" ] || printf '{}\n' > "$ISO_GLOBAL_CONFIG"
  jq --arg at "$now" --argjson v "${ISO_PREREQ_VERSION:-0}" \
     '.checked = {at: $at, version: $v}' \
     "$ISO_GLOBAL_CONFIG" > "$ISO_GLOBAL_CONFIG.tmp" \
    && mv "$ISO_GLOBAL_CONFIG.tmp" "$ISO_GLOBAL_CONFIG"
  iso_config_flush
}

iso_stamp_ok() {
  [ -f "$ISO_GLOBAL_CONFIG" ] || return 1
  [ "$(iso_config_get checked.version)" = "${ISO_PREREQ_VERSION:-0}" ]
}
