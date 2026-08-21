#!/usr/bin/env bash
# Multica adapter. Every multica CLI call in the codebase lives here and
# nowhere else, and so does every assumption about multica's JSON shape:
# list verbs return normalised lines, not raw vendor JSON, so a second adapter
# never has to imitate multica's field names.
# Sourced by tracking.sh; sets no shell options.
#
# Redaction is NOT done here — tracking.sh redacts before calling any verb that
# takes a body, so an adapter written in a hurry cannot skip it.

_M_LOG() { printf '%s' "${LOG:-/dev/null}"; }

# The authenticated human's name. `multica auth status` prints to stderr, not
# stdout, so the swap is load-bearing: a plain 2>/dev/null yields an empty lead
# and a project owned by nobody.
tk_current_user() {
  multica auth status 2>&1 >/dev/null \
    | sed -n 's/^User:[[:space:]]*\(.*\) (.*/\1/p' | head -1
}

# "<id>\t<title>" per line.
tk_project_list() {
  multica project list --output json 2>/dev/null \
    | jq -r '.[]? | "\(.id)\t\(.title)"' 2>/dev/null
}

# <title> [lead] -> id. No --priority flag exists on project create or update
# (CLI 0.4.26), so a new project lands at priority "none".
tk_project_create() {
  local title="$1" lead="${2:-}" args
  args=(project create --title "$title" --icon "🤖" --status in_progress --output json)
  [ -n "$lead" ] && args+=(--lead "$lead")
  multica "${args[@]}" 2>>"$(_M_LOG)" | jq -r '.id // empty' 2>/dev/null
}

# <project-id> <status> <title> <priority> [assignee]
# Body on stdin (may be empty). Prints the created issue key.
# One plan is one card, so there is no parent and no stage to pass.
tk_issue_create() {
  local project="$1" status="$2" title="$3" priority="$4"
  local assignee="${5:-}" body args
  body=$(cat)
  args=(issue create --title "$title" --project "$project" --status "$status" \
        --priority "$priority" --output json)
  [ -n "$assignee" ] && args+=(--assignee "$assignee")
  # --description-stdin, not --description: --description decodes \n and \\,
  # which mangles any code pasted into a prompt. Omitted entirely when the body
  # is empty, so the issue gets no description rather than a blank one.
  if [ -n "$body" ]; then
    printf '%s' "$body" | multica "${args[@]}" --description-stdin 2>>"$(_M_LOG)" \
      | jq -r '.identifier // .key // .id // empty' 2>/dev/null
  else
    multica "${args[@]}" 2>>"$(_M_LOG)" \
      | jq -r '.identifier // .key // .id // empty' 2>/dev/null
  fi
}

tk_issue_get_status() {
  multica issue get "$1" --output json 2>/dev/null | jq -r '.status // empty' 2>/dev/null
}

# --no-start is load-bearing: without it a status write can start an agent run,
# the one thing this design must never do.
tk_issue_status() { multica issue status "$1" "$2" --no-start >/dev/null 2>>"$(_M_LOG)"; }

# Replace the description. Body on stdin. --no-start for the usual reason:
# a write against the board must never enqueue an agent run.
tk_issue_describe() {
  multica issue update "$1" --description-stdin --no-start >/dev/null 2>>"$(_M_LOG)"
}

# Body on stdin.
tk_issue_comment()  { multica issue comment add "$1" --content-stdin >/dev/null 2>>"$(_M_LOG)"; }
tk_issue_label()    { multica issue label add "$1" "$2" >/dev/null 2>>"$(_M_LOG)"; }
tk_issue_property() { multica issue property set "$1" --name "$2" --value "$3" >/dev/null 2>>"$(_M_LOG)"; }

# "<id>\t<name>" per line.
tk_label_list() {
  multica label list --output json 2>/dev/null \
    | jq -r '(.labels? // .)[]? | "\(.id)\t\(.name)"' 2>/dev/null
}

# <name> <color> -> id.
tk_label_create() {
  multica label create --name "$1" --color "$2" --output json 2>>"$(_M_LOG)" \
    | jq -r '.id // empty' 2>/dev/null
}

# One property name per line.
tk_property_list() {
  multica property list --output json 2>/dev/null \
    | jq -r '(.properties? // .)[]? | .name' 2>/dev/null
}

# <name> <type>
tk_property_create() {
  multica property create --name "$1" --type "$2" --icon tag --output json \
    >/dev/null 2>>"$(_M_LOG)"
}
