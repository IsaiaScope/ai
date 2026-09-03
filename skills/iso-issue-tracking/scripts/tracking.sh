#!/usr/bin/env bash
# Work tracker, behind a swappable adapter. Called by the Claude Code session hooks (reconcile/end)
# and by the agent (bind/open/done). Outbound only — nothing here starts an
# agent.
# ponytail: one file. Every subcommand shares redact + the ledger; splitting it
# would buy nothing but an extra sourced path to get wrong.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"

TRACKER_KIND=$(iso_config_get tracker.kind)
# The ledger belongs to the tracker that wrote it -- a swap must not leave
# rows pointing at issue keys the new board never issued. tracker.ledger is
# therefore the full path, not a parent to append the kind to: appending it
# silently relocates an existing ledger, and the transition that follows
# reports "no ticket for plan" against an empty file it just created.
_ledger=$(iso_config_get tracker.ledger)
STATE="${ISO_TRACKER_STATE_DIR:-${MULTICA_STATE_DIR:-${_ledger/#\~/$HOME}}}"
LEDGER="$STATE/tracked.json"
PROJECTS="$STATE/projects.json"
LABELS="$STATE/labels.json"
PROPS="$STATE/properties.json"

# Closed vocabulary. Labels are durable and awkward to clean up, so a typo must
# not be able to mint a permanent one. Emoji carries the TYPE of change; labels
# carry the AREA, and a row may carry several.
SCOPES="fe be db data ai api auth ci gh vps security doc test perf"

# medium is the floor, not "none": a board where everything is unprioritised
# sorts by nothing at all.
PRIORITIES="urgent high medium low none"
LOG="$STATE/log"

# Idempotent by nature, so the second call onwards is pure fork. 24 call sites
# reach it, and a single `open` run used to pay for `mkdir -p` a dozen times.
_STATE_READY=0
state_dir() {
  [ "$_STATE_READY" = 1 ] && return 0
  mkdir -p "$STATE" 2>/dev/null
  [ -f "$LEDGER" ] || echo '{}' > "$LEDGER" 2>/dev/null
  _STATE_READY=1
}
logf() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null; }

# The board behind the tk_* verbs. An unknown kind falls back to `none`
# rather than dying: tracking must never be able to fail the run that
# invoked it, which is the rule every call site already relies on.
_adapter="$HERE/adapters/${TRACKER_KIND}.sh"
if [ ! -f "$_adapter" ]; then
  logf "unknown tracker.kind '$TRACKER_KIND' -- falling back to none"
  _adapter="$HERE/adapters/none.sh"
fi
# shellcheck source=/dev/null
. "$_adapter"

# Trust boundary: everything sent to the board passes through here.
redact() {
  sed -E \
    -e 's/mul_[A-Za-z0-9]{16,}/[redacted]/g' \
    -e 's/sk-[A-Za-z0-9_-]{16,}/[redacted]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{16,}/[redacted]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[redacted]/g' \
    -e 's/AGE-SECRET-KEY-[A-Z0-9]{20,}/[redacted]/g' \
    -e 's/-----BEGIN [A-Z ]*KEY-----/[redacted]/g' \
    -e 's/[0-9a-f]{32,}/[redacted]/g'
}

# Project name from the git remote; "scratch" outside a repo.
project_for() {
  local d="${1:-$PWD}" url
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || { echo scratch; return 0; }
  [ -n "$url" ] || { echo scratch; return 0; }
  basename "$url" .git
}

# The configured development branch, then develop, then origin's default. NOT
# main by convention. The candidates come from iso-config so that renaming
# branches.development reaches the reconciler too — this list used to be a
# second, private copy that a rename silently left behind.
integration_branch() {
  local d="${1:-$PWD}" b
  for b in $(iso_integration_candidates); do
    git -C "$d" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return 0; }
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$b" && { echo "$b"; return 0; }
  done
  b=$(git -C "$d" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) \
    && { echo "${b##*/}"; return 0; }
  echo ""
}

ledger_get() { state_dir; jq -r --arg k "$1" '.[$k] // empty' "$LEDGER" 2>/dev/null; }
ledger_put() {
  state_dir; local tmp; tmp=$(mktemp)
  jq --arg k "$1" --argjson v "$2" '.[$k]=$v' "$LEDGER" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$LEDGER" || rm -f "$tmp"
}
ledger_del() {
  state_dir; local tmp; tmp=$(mktemp)
  jq --arg k "$1" 'del(.[$k])' "$LEDGER" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$LEDGER" || rm -f "$tmp"
}

# `plan` is an array of {path,state,body}: one branch carries many plans, and a
# ticket that can only name its newest one has to destroy the others to stay
# accurate. Rows written before this change hold a bare string, so coerce on
# read - two live rows is fewer than a migration script is worth.
# state is exactly one of: done | current | superseded.
plan_entries() {
  state_dir
  local out
  # jq on empty input prints nothing and still exits 0, so a `|| echo []`
  # fallback never fires for a row that does not exist. Check the value, not
  # the exit status: an empty string reaching --argjson kills the write.
  out=$(ledger_get "$1" | jq -c '
    (.plan // null) as $p
    | if   ($p | type) == "array"  then $p
      elif ($p | type) == "string" then
        (if $p == "" then [] else [{path:$p, state:"current", body:""}] end)
      else [] end' 2>/dev/null)
  [ -n "$out" ] || out='[]'
  printf '%s' "$out"
}
# so a repeated call is idempotent instead of growing the row.
plan_push() {
  local key="$1" path="$2" outgoing="$3" body="${4:-}" row entries
  row=$(ledger_get "$key"); [ -n "$row" ] || return 1
  entries=$(plan_entries "$key" | jq -c \
    --arg p "$path" --arg o "$outgoing" --arg b "$body" '
      map(if .state == "current" then .state = $o else . end)
      | map(select(.path != $p))
      + [{path:$p, state:"current", body:$b}]' 2>/dev/null) || return 1
  ledger_put "$key" "$(printf '%s' "$row" | jq -c --argjson e "$entries" '.plan = $e' 2>/dev/null)"
}

plan_current() {
  plan_entries "$1" | jq -r 'map(select(.state=="current")) | .[0].path // empty' 2>/dev/null
}

# Reverse lookup: identifier -> ticket key. Named for what it takes rather than
# for one of the two things it takes — half the call sites hand it a branch
# (/iso-push and /iso-commit hold no plan path), so `ticket_for_plan "$br"` read
# like a bug at every one of them.
# The ledger is keyed by issue, so this
# is a scan; it holds one row per open branch, not a history, so a scan is
# cheaper than a second index that can drift.
# Matched on basename: /iso-plan records whatever path it was given and
# /iso-write may hand back a different spelling of the same file. An exact
# string compare would silently no-op, which is the failure this replaces.
# A branch name resolves too, because /iso-push holds a branch and never a
# plan path - the ledger already stores the branch for the reconciler.
# Scoped to this checkout, because the ledger is one file for every repo on the
# machine and every repo has a `dev`: an unscoped branch match handed back some
# other repo's ticket, and a rebranch then wrote this repo's branch name onto
# it. Rows written before .repo existed carry none and stay visible everywhere -
# stranding them is worse than the collision they risk.
ticket_for() {
  local plan="${1:-}" base keys key elsewhere
  [ -n "$plan" ] || return 1
  base=${plan##*/}
  state_dir
  # Every path in the plan array, not only the newest: a session resumed on an
  # older plan must find the same ticket, and a lookup that comes back empty is
  # exactly what mints a duplicate.
  keys=$(jq -r --arg b "$base" --arg a "$plan" --arg r "$(project_for "$PWD")" '
    to_entries[]
    | select(((.value.repo // "") == "") or ((.value.repo // "") == $r))
    | . as $e
    | ( ($e.value.plan // []) as $p
        | if   ($p | type) == "array"  then ($p | map(.path // ""))
          elif ($p | type) == "string" then [$p]
          else [] end ) as $paths
    | select( (($paths | map(split("/") | last) | index($b)) != null)
              or (($e.value.branch // "") == $a) )
    | $e.key' "$LEDGER" 2>/dev/null)
  # A row that matched on identifier but lost on repo scope is not the same as
  # no row at all: the first means "you are in the wrong checkout", the second
  # means "this is new work". Silence made them identical, and only one of them
  # should lead to a new ticket.
  if [ -z "$keys" ]; then
    elsewhere=$(jq -r --arg b "$base" --arg a "$plan" '
      to_entries[]
      | . as $e
      | ( ($e.value.plan // []) as $p
          | if   ($p | type) == "array"  then ($p | map(.path // ""))
            elif ($p | type) == "string" then [$p]
            else [] end ) as $paths
      | select( (($paths | map(split("/") | last) | index($b)) != null)
                or (($e.value.branch // "") == $a) )
      | "\($e.key) in \($e.value.repo // "?")"' "$LEDGER" 2>/dev/null | head -3)
    if [ -n "$elsewhere" ]; then
      logf "ticket_for: $plan matches only rows in another repo: $(printf '%s' "$elsewhere" | tr '\n' ';')"
      printf 'tracking: %s is tracked in another checkout (%s) -- not visible from %s\n' \
        "$plan" "$(printf '%s' "$elsewhere" | tr '\n' ';')" "$(project_for "$PWD")" >&2
    fi
    return 1
  fi
  key=$(printf '%s\n' "$keys" | head -1)
  # More than one row for one identifier is the bug this design exists to stop.
  # One key is still returned, because every caller wants one - but silence here
  # is how FIRE-21 stayed invisible for a day.
  if [ "$(printf '%s\n' "$keys" | grep -c .)" -gt 1 ]; then
    logf "ticket_for: $plan matches several rows: $(printf '%s' "$keys" | tr '\n' ' ')-- using $key"
    printf 'tracking: %s matches several tickets (%s) -- using %s\n' \
      "$plan" "$(printf '%s' "$keys" | tr '\n' ' ')" "$key" >&2
  fi
  echo "$key"
  return 0
}

# One plan, one ticket. There is nothing to fan out to.
# A miss also goes to stderr, not just the log: the whole point of these writes
# is that the board matches reality, and a transition that quietly moved nothing
# is indistinguishable from one that worked until someone opens the board days
# later. Still returns 0 - visible, never fatal.
move_plan_ticket() {
  local want="$1" plan="${2:-}" key
  key=$(ticket_for "$plan") \
    || { logf "$want: no ticket for plan ${plan:-<none>}"
         printf 'tracking: no ticket matches %s -- board not moved to %s\n' \
           "${plan:-<none>}" "$want" >&2
         return 0; }
  set_status "$key" "$want" && logf "$key -> $want (plan ${plan##*/})"
  return 0
}

session_file() { echo "$STATE/session-${1:-unknown}.json"; }
bound_issue() {
  local f; f=$(session_file "$1")
  [ -f "$f" ] && jq -r '.issue // empty' "$f" 2>/dev/null || true
}

# Fire-and-forget. --content-stdin, not --content: --content decodes \n and \\,
# which mangles any code pasted into a prompt.
comment_bg() {
  local key="$1" body="$2"
  ( printf '%s' "$body" | tk_issue_comment "$key" \
      || logf "comment add $key failed" ) &
  disown 2>/dev/null || true
}

# --no-start is enforced in the adapter's tk_issue_status, not here: the flag
# and its reason sit on that one line, in whichever adapter is loaded. Naming
# the adapter here would put a vendor name in this file, which contract.test.sh
# forbids — and rightly, since the point is that this layer does not know one.
set_status() {
  local key="$1" want="$2" got
  tk_issue_status "$key" "$want" || { logf "status write refused: $key -> $want"; return 1; }
  # Read it back. FIRE-19 was logged "-> done" and dropped from the ledger while
  # the board stayed in_review: the write returned success, the transition never
  # happened, and nothing would ever move that row again.
  got=$(tk_issue_get_status "$key")
  [ -z "$got" ] && return 0          # cannot verify; do not invent a failure
  [ "$got" = "$want" ] && return 0
  logf "status did not stick: $key wanted $want, board says $got"
  printf 'tracking: %s did not move to %s (board says %s)\n' "$key" "$want" "$got" >&2
  return 1
}

current_user_name() { tk_current_user; }

# title -> id cache; issue create takes an id, not a title.
project_id_for() {
  local name="$1" id tmp
  state_dir; [ -f "$PROJECTS" ] || echo '{}' > "$PROJECTS"
  id=$(jq -r --arg n "$name" '.[$n] // empty' "$PROJECTS" 2>/dev/null)
  [ -n "$id" ] && { echo "$id"; return 0; }
  id=$(tk_project_list | awk -F'\t' -v n="$name" '$2==n {print $1; exit}')
  if [ -z "$id" ]; then
    # No --priority flag exists on project create or update (CLI 0.4.26), so a
    # new project lands at priority "none" and has to be set in the UI.
    id=$(tk_project_create "$name" "$(current_user_name)")
  fi
  [ -z "$id" ] && { logf "could not resolve project $name"; return 1; }
  tmp=$(mktemp)
  jq --arg n "$name" --arg i "$id" '.[$n]=$i' "$PROJECTS" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$PROJECTS" || rm -f "$tmp"
  echo "$id"
}

# Fixed map, not a hash. The vocabulary is closed, so a lookup is shorter and
# collision-free; hashing known strings into fewer buckets collides for no gain.
label_color_for() {
  case "$1" in
    fe)       echo "#3b82f6" ;;   # blue
    be)       echo "#8b5cf6" ;;   # violet
    db)       echo "#0ea5e9" ;;   # sky
    data)     echo "#ec4899" ;;   # pink
    ai)       echo "#a855f7" ;;   # purple
    api)      echo "#06b6d4" ;;   # cyan
    auth)     echo "#f43f5e" ;;   # rose
    ci)       echo "#14b8a6" ;;   # teal
    gh)       echo "#64748b" ;;   # slate
    vps)      echo "#f97316" ;;   # orange
    security) echo "#ef4444" ;;   # red
    doc)      echo "#f59e0b" ;;   # amber
    test)     echo "#10b981" ;;   # green
    perf)     echo "#84cc16" ;;   # lime
    *)        echo "#6b7280" ;;   # grey, unreachable while SCOPES is enforced
  esac
}

# Custom property definitions are workspace-wide and owner-only, so create once
# and cache the fact. Values are addressed by name afterwards, so no id to keep.
ensure_property() {
  local name="$1" type="$2" tmp
  state_dir; [ -f "$PROPS" ] || echo '{}' > "$PROPS"
  [ "$(jq -r --arg n "$name" '.[$n] // empty' "$PROPS" 2>/dev/null)" = "1" ] && return 0
  if ! tk_property_list | grep -qxF "$name"; then
    tk_property_create "$name" "$type" \
      || { logf "could not create property $name"; return 1; }
  fi
  tmp=$(mktemp)
  jq --arg n "$name" '.[$n]="1"' "$PROPS" > "$tmp" 2>/dev/null && mv "$tmp" "$PROPS" || rm -f "$tmp"
}

# name -> id, same cache/lookup/create shape as project_id_for. issue create has
# no --label flag, so the label is attached after the issue exists.
label_id_for() {
  local name="$1" id tmp
  state_dir; [ -f "$LABELS" ] || echo '{}' > "$LABELS"
  id=$(jq -r --arg n "$name" '.[$n] // empty' "$LABELS" 2>/dev/null)
  [ -n "$id" ] && { echo "$id"; return 0; }
  id=$(tk_label_list | awk -F'\t' -v n="$name" '$2==n {print $1; exit}')
  if [ -z "$id" ]; then
    id=$(tk_label_create "$name" "$(label_color_for "$name")")
  fi
  [ -z "$id" ] && { logf "could not resolve label $name"; return 1; }
  tmp=$(mktemp)
  jq --arg n "$name" --arg i "$id" '.[$n]=$i' "$LABELS" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$LABELS" || rm -f "$tmp"
  echo "$id"
}

# Shared by the bind arm and by open. A function, not a re-exec: open would
# otherwise depend on the script being +x, which packaging can get wrong.
do_bind() {
  local sid="$1" key="$2" who="${3:-iso}" plan="${4:-}" promote="${5:-1}" br proj st row entries
  [ -n "$sid" ] && [ -n "$key" ] || { logf "bind needs <session_id> <key>"; return 1; }
  br=$(iso_current_branch)
  proj=$(project_for "$PWD")
  printf '{"issue":"%s"}' "$key" > "$(session_file "$sid")" 2>/dev/null
  # Merge into the row, never replace it. The ledger row is an open object -
  # other arms and future ones write fields do_bind knows nothing about, and a
  # wholesale rewrite dropped them silently.
  row=$(ledger_get "$key"); [ -n "$row" ] || row='{}'
  entries=$(plan_entries "$key")
  # bind means "this is the plan being worked now", so the given plan must end up
  # current. addplan and replan have already settled the outgoing entry with
  # their own state by the time they call this, so it is a no-op for them; a bare
  # `bind` gets addplan's reading, and `replan` is the explicit way to say the
  # previous plan was wrong instead.
  if [ -n "$plan" ]; then
    entries=$(printf '%s' "$entries" | jq -c --arg p "$plan" '
      if ((map(select(.state == "current")) | .[0].path // "") == $p) then .
      else ( map(if .state == "current" then .state = "done" else . end)
             | map(select(.path != $p))
             + [{path:$p, state:"current", body:""}] )
      end' 2>/dev/null)
    [ -n "$entries" ] || entries=$(jq -nc --arg p "$plan" '[{path:$p, state:"current", body:""}]')
  fi
  ledger_put "$key" "$(printf '%s' "$row" | jq -c \
    --arg r "$proj" --arg b "$br" --arg o "$who" --argjson e "$entries" \
    '. + {repo:$r, branch:$b, project:$r, opened_by:$o, plan:$e}' 2>/dev/null)"
  # Branch on the ticket, not only in the local ledger: the board should stay
  # readable without the local ledger, and from another machine.
  if [ -n "$br" ]; then
    ensure_property Branch text \
      && { tk_issue_property "$key" Branch "$br" \
           || logf "branch property set failed on $key"; }
  fi

  # `bind` attaches a session to work already underway, so it promotes.
  # `open` does not: /iso-plan leaves the ticket at todo and /iso-write owns the
  # move to in_progress. Promoting here would write a status nobody asked for.
  if [ "$promote" = "1" ]; then
    st=$(tk_issue_get_status "$key")
    case "$st" in
      backlog|todo) set_status "$key" in_progress && logf "bind $key: $st -> in_progress" ;;
    esac
  fi
  return 0
}

# Section heading from a plan filename. Derived, never passed in: one more flag
# on addplan is one more thing a caller gets wrong, and the filename already
# carries the name someone chose for this plan.
plan_label() {
  local base="${1##*/}"
  base="${base%.md}"
  base=$(printf '%s' "$base" \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/^(feat|fix|chore|refactor|docs?|test|perf|style|build)-//')
  printf '%s' "${base//-/ }"
}

# The whole ticket description, rendered from the plan array. Pure: no board
# read, no remote state, so the same entries always produce the same bytes and a
# damaged description is repaired by rendering it again. This is what makes a
# multi-plan body safe - the alternative, read-modify-write against the board,
# is what deleted the first plan on FIRE-20.
# Markers are single codepoints on purpose: the variation-selector form of the
# triangle is a format character, and it does not survive every pipe it passes
# through on the way to the board.
# $1 session id, $2 agent kind, $3 intro prose (may be empty), $4 entries JSON.
render_body() {
  local sid="$1" agent="$2" intro="$3" entries="${4:-[]}"
  local out="" path state body label marker cur=""
  [ -n "$intro" ] && out="$intro"
  # The body travels in the same row, base64'd. Re-querying `$entries` per row
  # for a field the first query was already holding cost one jq fork per plan;
  # base64 because a body carries newlines and tabs, which @tsv cannot.
  while IFS=$'\t' read -r path state b64; do
    [ -n "$path" ] || continue
    case "$state" in
      done)       marker="✅" ;;
      superseded) marker="⊘"  ;;
      *)          marker="▶"  ; cur="$path" ;;
    esac
    label=$(plan_label "$path")
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    if [ -n "$out" ]; then
      out=$(printf '%s\n\n## %s %s\n\n`%s` - %s' "$out" "$marker" "$label" "$path" "$state")
    else
      out=$(printf '## %s %s\n\n`%s` - %s' "$marker" "$label" "$path" "$state")
    fi
    [ -n "$body" ] && out=$(printf '%s\n\n%s' "$out" "$body")
  done <<< "$(printf '%s' "$entries" \
    | jq -r '.[]? | [.path, .state, ((.body // "") | @base64)] | @tsv' 2>/dev/null)"
  # Footer once, at the end - not once per section. Only the current plan gets a
  # runnable command; a `/iso-write` on a shipped or abandoned plan is a trap.
  printf '%s' "$out" | ticket_body "$sid" "$agent" "$cur"
}

# The ticket body a caller pipes in, plus the two resume blocks. Shared by `open`
# and `replan` so a replanned ticket is shaped exactly like a fresh one - a ticket
# whose footer depends on which verb last touched it is a ticket you have to read
# twice. $1 session id, $2 agent kind, $3 plan path (may be empty).
# Body on stdin; prints the finished description.
ticket_body() {
  local sid="$1" agent="$2" plan="${3:-}" desc="" resume root
  [ -t 0 ] || desc=$(cat 2>/dev/null | redact | head -c 8000 || true)
  # Resume block, appended after redaction so the command is never mangled.
  # The script already knows the session id, so this cannot be forgotten - and
  # a session uuid survives redact because its dashes break the hex run.
  # Only when claude is doing the work. --agent codex means the work happens in
  # a session this command cannot reach, and a resume line that resumes nothing
  # is worse than none - it reads as an offer.
  # Two blocks, not one line: resume the session, then paste the slash command
  # into it. Separate so each copies on its own - the resume is worth running
  # by itself to read the session back, and the invocation is what you paste
  # once you are in. The plan path is never retyped by hand either way.
  if [ "$agent" = "claude" ]; then
    # cd first: the ticket is read from anywhere, and `claude --resume` binds to
    # the directory it starts in. One line so it stays a single copy-paste.
    root=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
    resume=$(printf '**Resume this session:**\n\n```bash\ncd %s && claude --resume %s --dangerously-skip-permissions\n```' "$root" "$sid")
    if [ -n "$plan" ]; then
      resume=$(printf '%s\n\n**Then implement the plan:**\n\n```\n/iso-write %s\n```' "$resume" "$plan")
    fi
    if [ -n "$desc" ]; then desc=$(printf '%s\n\n---\n\n%s' "$desc" "$resume")
    else desc="$resume"; fi
  fi
  printf '%s' "$desc"
}

# The live ticket for the branch checked out right now, or nothing. "Live" excludes
# done and cancelled: that work shipped, and a new plan against it is new work,
# not a second attempt at the old one.
ticket_for_branch() {
  local br key st
  br=$(iso_current_branch)
  [ -n "$br" ] || return 1
  key=$(ticket_for "$br") || return 1
  st=$(tk_issue_get_status "$key")
  case "$st" in done|cancelled) return 1 ;; esac
  printf '%s\t%s\n' "$key" "$st"
}

# Sourced by the self-check to exercise the functions in isolation. Without
# this the dispatch below runs and `exit 0` kills the sourcing shell, which
# would make the whole test file pass by printing nothing.
(return 0 2>/dev/null) && return 0

# Installed globally, so it runs in every directory the agent opens. Outside a
# repo there is no project to file against and no branch to reconcile, and a
# project minted for ~/Downloads is noise nobody asked for. Placed after the
# sourced-guard: the self-check sources this file and must not be gated.
# Installed globally, so it runs in every directory the agent opens. Outside a
# repo there is nothing to file against - but exiting without a word made a
# lookup run from the wrong directory indistinguishable from one that found
# nothing, which is one way a duplicate ticket gets minted.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  logf "not a git repo ($PWD), skipping ${1:-<none>}"
  exit 0
fi

case "${1:-}" in

  end)
    state_dir
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    issue=$(bound_issue "$sid")
    if [ -n "$issue" ]; then
      comment_bg "$issue" "Claude Code session ended. Status unchanged - closure is decided by the reconciler when the branch merges."
      rm -f "$(session_file "$sid")"
    fi
    ;;

  bind)
    state_dir
    do_bind "${2:-}" "${3:-}" "${4:-iso}" && echo "${3:-}"
    ;;

  # The three writes the iso-* chain makes at its own boundaries. Each takes a
  # plan path because that is the only identifier /iso-write and /iso-push both
  # hold; neither knows a session id or an issue key.
  # The merge is the one moment where "it shipped" and "someone still remembers
  # why" overlap. The reconciler can see a merge but never the story, so it
  # closes without a retro; this arm is the path that has both.
  # stdin: the retro body, as-is.
  retro)
    state_dir
    plan="${2:-}"
    key=$(ticket_for "$plan") \
      || { logf "retro: no ticket for plan ${plan:-<none>}"; exit 0; }
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 4000 || true)
    if [ -n "$body" ]; then
      printf '%s' "$body" | tk_issue_comment "$key" \
        || logf "retro: comment failed on $key"
    fi
    set_status "$key" done && logf "$key -> done (retro, plan ${plan##*/})"
    ledger_del "$key"
    ;;

  # Is there a live ticket for the branch I am on? Prints "<KEY>\t<status>" or
  # nothing. /iso-plan asks this before writing a ticket: on a base branch it is
  # empty and a fresh ticket is opened, on a feature branch that already carries
  # work it names the ticket to replan against.
  ticket-for-branch)
    state_dir
    ticket_for_branch || exit 0
    ;;

  # The branch a ticket lives on changes after the ticket is opened: /iso-write
  # cuts one from the plan filename, /iso-push rescues commits off a protected
  # branch, /iso-commit gates before the commit lands. Both the ledger row and
  # the board have to follow, and the ledger is the one that bites - it is the
  # key ticket_for_branch resolves by, so a stale row makes the ticket
  # unfindable from the branch the work is actually on.
  # $2 identifies the ticket: a plan path, or the branch it is moving OFF.
  # Resolve BEFORE the ledger write; afterwards the old identifier matches
  # nothing and a second run would look like a miss.
  # No ticket comment: a branch move is bookkeeping, and one comment per move
  # buries the retro that actually matters.
  rebranch)
    state_dir
    ident="${2:-}"; newbr="${3:-}"
    [ -n "$ident" ] && [ -n "$newbr" ] \
      || { logf "rebranch needs <identifier> <new-branch>"; exit 0; }
    key=$(ticket_for "$ident") \
      || { logf "rebranch: no ticket for $ident"; exit 0; }
    row=$(ledger_get "$key")
    ledger_put "$key" "$(printf '%s' "$row" | jq -c --arg b "$newbr" '.branch=$b' 2>/dev/null)"
    ensure_property Branch text \
      && { tk_issue_property "$key" Branch "$newbr" \
           || logf "rebranch: branch property set failed on $key"; }
    logf "rebranch $key -> $newbr (from $ident)"
    ;;

  # The read half. /iso-commit needs the ticket's branch to offer a resume and
  # holds no plan path, so it cannot reach the ledger any other way.
  branch-of)
    state_dir
    key=$(ticket_for "${2:-}") || exit 0
    ledger_get "$key" | jq -r '.branch // empty' 2>/dev/null
    ;;

  # A further plan on a branch that already has one. The previous plan shipped -
  # that is the whole difference from `replan`, where it was wrong. Both keep
  # every plan visible; only the state on the outgoing entry differs.
  # stdin: this plan's section body.
  addplan)
    state_dir
    sid="${2:-}"; plan=""; key=""; agent=claude; title=""; intro=""
    shift 2 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan)  plan="${2:-}";  shift 2 ;;
        --key)   key="${2:-}";   shift 2 ;;
        --agent) agent="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        --intro) intro="${2:-}"; shift 2 ;;
        *) logf "addplan: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$plan" ]; then
      logf "addplan needs <session_id> --plan <path>"; exit 0
    fi
    if [ -z "$key" ]; then
      key=$(ticket_for_branch | cut -f1)
      if [ -z "$key" ]; then
        logf "addplan: no live ticket for this branch -- open one instead"
        printf 'tracking: no live ticket for this branch -- nothing to add to\n' >&2
        exit 0
      fi
    fi
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 8000 || true)
    was=$(plan_current "$key")
    plan_push "$key" "$plan" done "$body" \
      || { logf "addplan: no ledger row for $key"; exit 0; }
    desc=$(render_body "$sid" "$agent" "$intro" "$(plan_entries "$key")")
    if [ -n "$desc" ]; then
      printf '%s' "$desc" | tk_issue_describe "$key" \
        || logf "addplan: description update failed on $key"
    fi
    if [ -n "$title" ]; then
      safe=$(printf '%s' "$title" | redact | head -c 200)
      tk_issue_title "$key" "$safe" \
        && logf "$key retitled: $safe" \
        || logf "retitle failed on $key"
    fi
    printf 'Plan added - `%s` continues from `%s`, which is done. The description above carries both.\n' \
      "$plan" "${was:-<none>}" | redact | tk_issue_comment "$key" \
      || logf "addplan: comment failed on $key"
    st=$(tk_issue_get_status "$key")
    case "$st" in
      todo|backlog|in_review|blocked)
        set_status "$key" in_progress \
          && logf "$key -> in_progress (addplan, ${plan##*/}, was ${was:-<none>}, from $st)" ;;
      *) logf "$key addplan ${plan##*/} (was ${was:-<none>}, status $st unchanged)" ;;
    esac
    do_bind "$sid" "$key" claude "$plan" 0
    echo "$key"
    ;;

  # A second plan for work already ticketed. The first attempt was wrong, or it
  # came back from review needing a different approach - that is the same piece
  # of work, so it is the same ticket. A second ticket would split one story across
  # two rows and leave the first sitting in_review for good.
  # Back to todo, because a new plan means nothing has been implemented yet.
  # stdin: the new ticket body, same shape as `open`.
  replan)
    state_dir
    sid="${2:-}"; plan=""; key=""; agent=claude; intro=""; title=""
    shift 2 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan)  plan="${2:-}"; shift 2 ;;
        --key)   key="${2:-}";  shift 2 ;;
        --agent) agent="${2:-}"; shift 2 ;;
        --intro) intro="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) logf "replan: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$plan" ]; then
      logf "replan needs <session_id> --plan <path>"; exit 0
    fi
    # An explicit --key wins: the caller was told which ticket by a human, and a
    # branch lookup that disagrees is the lookup being wrong, not the human.
    if [ -z "$key" ]; then
      key=$(ticket_for_branch | cut -f1)
      if [ -z "$key" ]; then
        logf "replan: no live ticket for this branch -- open a new one instead"
        printf 'tracking: no live ticket to replan -- opening a new one\n' >&2
        exit 0
      fi
    fi
    st=$(tk_issue_get_status "$key")
    case "$st" in
      done|cancelled)
        logf "replan: $key is $st -- that work shipped, open a new ticket"
        printf 'tracking: %s is %s, not replanning it\n' "$key" "$st" >&2
        exit 0 ;;
    esac
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 8000 || true)
    was=$(plan_current "$key")
    # Superseded, not deleted. The old arm replaced the whole description with
    # the new plan, so the abandoned one survived only as a filename in a
    # comment - which is how FIRE-20 lost its first plan.
    plan_push "$key" "$plan" superseded "$body" \
      || { logf "replan: no ledger row for $key"; exit 0; }
    desc=$(render_body "$sid" "$agent" "$intro" "$(plan_entries "$key")")
    if [ -n "$desc" ]; then
      printf '%s' "$desc" | tk_issue_describe "$key" \
        || logf "replan: description update failed on $key"
    fi
    if [ -n "$title" ]; then
      safe=$(printf '%s' "$title" | redact | head -c 200)
      tk_issue_title "$key" "$safe" \
        && logf "$key retitled: $safe" \
        || logf "retitle failed on $key"
    fi
    printf 'Replanned from `%s` - superseded by `%s`. Back to `todo`; both remain in the description above.\n' \
      "${was:-<none>}" "$plan" | redact | tk_issue_comment "$key" \
      || logf "replan: comment failed on $key"
    set_status "$key" todo \
      && logf "$key -> todo (replan, ${plan##*/}, was ${was:-<none>}, from $st)"
    do_bind "$sid" "$key" claude "$plan" 0
    echo "$key"
    ;;

  progress|review|blocked)
    state_dir
    case "$1" in
      progress) want=in_progress ;;
      review)   want=in_review ;;
      blocked)  want=blocked ;;
    esac
    move_plan_ticket "$want" "${2:-}"
    ;;

  open)
    state_dir
    sid="${2:-}"; title="${3:-}"; scope=""; priority=""; agent=claude; plan=""; intro=""
    shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --scope)  scope="$scope ${2:-}"; shift 2 ;;
        --plan)   plan="${2:-}"; shift 2 ;;
        --priority) priority="${2:-}"; shift 2 ;;
        --agent)    agent="${2:-}"; shift 2 ;;
        --intro)    intro="${2:-}"; shift 2 ;;
        *) logf "open: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$title" ]; then logf "open needs <session_id> <title>"; exit 0; fi
    # One branch, one ticket. The rule used to live in a SKILL.md, which held
    # exactly as long as the caller read the right document - and on 2026-08-28
    # one did not, producing a second row on a branch that already had one.
    # Redirect rather than refuse: a refusal hands the decision back to whoever
    # already skipped one, and a caller that cannot create a ticket may cut a
    # new branch instead. There is deliberately no --force-new.
    # Base branches are exempt. `dev` accumulates unrelated tickets by design -
    # /iso-plan opens on it and /iso-write rebranches afterwards - so a gate that
    # fired there would fold every plan written back-to-back into one ticket.
    # The invariant this enforces is about feature branches, which is where a
    # duplicate actually splits one story in two.
    cur_br=$(iso_current_branch)
    held=""
    if iso_is_protected "$cur_br"; then
      logf "open: $cur_br is a base branch, no branch gate applied"
    else
      held=$(ticket_for_branch | cut -f1)
    fi
    if [ -n "$held" ]; then
      # The title is deliberately NOT forwarded. It was written for a ticket
      # that is not going to exist, and applying it would rename the existing
      # ticket to describe only its newest plan - the drift this design removes.
      # Broadening a title is an explicit `addplan --title`, never a side effect.
      logf "open: redirect to addplan on $held (branch already tracked; title not applied: $title)"
      printf 'tracking: this branch is already tracked by %s -- adding the plan there (title left alone)\n' "$held" >&2
      # An args array, not word-splitting: an intro contains spaces and
      # ${intro:+--intro "$intro"} would shatter it into separate arguments.
      redirect=(addplan "$sid" --key "$held" --plan "$plan" --agent "$agent")
      [ -n "$intro" ] && redirect+=(--intro "$intro")
      # exec, so stdin is inherited unread and the piped body reaches addplan
      # intact. Nothing above this point may consume stdin.
      exec "$0" "${redirect[@]}"
    fi
    [ -z "$priority" ] && priority="medium"
    if ! printf '%s' " $PRIORITIES " | grep -q " $priority "; then
      logf "open: unknown priority '$priority', using medium (valid: $PRIORITIES)"
      priority="medium"
    fi

    # --scope may repeat and may carry a comma list: --scope fe,be --scope ci
    valid_scopes=""
    for sc in $(printf '%s' "$scope" | tr ',' ' '); do
      if printf '%s' " $SCOPES " | grep -q " $sc "; then
        case " $valid_scopes " in *" $sc "*) ;; *) valid_scopes="$valid_scopes $sc" ;; esac
      else
        logf "open: unknown scope '$sc', dropping it (valid: $SCOPES)"
      fi
    done

    proj=$(project_for "$PWD")
    pid=$(project_id_for "$proj") || exit 0
    safe=$(printf '%s' "$title" | redact | head -c 200)

    # Description arrives on stdin: multi-line, no arg-quoting, and it still
    # goes through redact because it is the same trust boundary as a comment.
    #
    # --intro is a forwarding hook for the redirect above, not a second way to
    # write this body: `open` has no plan sections to sit above, so there is
    # nothing for an intro to introduce. Logged rather than dropped in silence,
    # because the same command line keeps the prose when the branch already
    # holds a ticket -- so a caller who reaches this arm has lost bytes it saw
    # survive the last time, and the log is the only place that can say so.
    [ -n "$intro" ] && logf "open: --intro ignored on a fresh ticket, put the prose on stdin"
    desc=$(ticket_body "$sid" "$agent" "$plan")

    # --status todo, not in_progress: do_bind does the promotion, and that is
    # the path that passes --no-start.
    # Assignee is the authenticated human, so this cannot enqueue an agent run;
    # the status promotion in do_bind passes --no-start for the same reason.
    who=$(current_user_name)
    key=$(printf '%s' "$desc" | tk_issue_create "$pid" todo "$safe" "$priority" "$who")
    if [ -z "$key" ]; then logf "open failed for: $safe"; exit 0; fi
    logf "open $key: $safe (project $proj, branch $(iso_current_branch), plan ${plan:-<none>})"

    # Scope label, best-effort: a missing label is cosmetic, not a reason to
    # leave the row unbound. The repo is already the project, so labelling by
    # repo would just restate it.
    for sc in $valid_scopes; do
      lid=$(label_id_for "$sc") && [ -n "$lid" ] \
        && { tk_issue_label "$key" "$lid" \
             || logf "label add $key $sc failed"; }
    done

    do_bind "$sid" "$key" claude "$plan" 0
    echo "$key"
    ;;

  done)
    state_dir
    sid="${2:-}"; key="${3:-}"
    [ -z "$key" ] && key=$(bound_issue "$sid")
    if [ -z "$key" ]; then logf "done: nothing bound"; exit 0; fi
    set_status "$key" done && logf "done $key (override)"
    ledger_del "$key"
    echo "$key"
    ;;

  reconcile)
    state_dir
    repo_dir="$PWD"
    here=$(project_for "$repo_dir")
    ib=$(integration_branch "$repo_dir")
    if [ -z "$ib" ]; then logf "reconcile: no integration branch, skipping"; exit 0; fi

    # Nothing tracked means nothing to reconcile. Checked before gh, because an
    # empty ledger is the common case on session start and gh costs ~0.5s.
    [ "$(jq -r 'keys|length' "$LEDGER" 2>/dev/null || echo 0)" = "0" ] && exit 0

    # gh is the authoritative merge signal. This repo rebases onto dev before
    # merging, so ancestry alone cannot tell a rebase-merged branch from an
    # abandoned one. Without gh, cancellation is skipped for the whole run.
    prs=$(cd "$repo_dir" && gh pr list --state all --limit 200 \
            --json headRefName,state 2>/dev/null)
    gh_ok=0; [ -n "$prs" ] && gh_ok=1
    [ "$gh_ok" -eq 0 ] && logf "reconcile: gh unavailable - no cancellation this run"

    # One jq for the whole PR list, one for the whole ledger. Both used to be
    # re-parsed per row - the 200-record PR blob twice and the ledger four
    # times - which put ~7 jq processes per open ticket on every session start.
    # Now the loop forks nothing to read a field.
    pr_map=$(printf '%s' "$prs" | jq -r \
      '.[]? | [.headRefName, .state] | @tsv' 2>/dev/null)
    rows=$(jq -r 'to_entries[]
      | [.key, (.value.branch // ""), (.value.opened_by // "iso"),
         (.value.repo // "")] | @tsv' "$LEDGER" 2>/dev/null)

    # Loop-invariant: the integration tip does not move while the loop runs, and
    # resolving it per row cost one git fork per open ticket on every session
    # start. Same standard the pr_map/rows comment above sets for jq.
    ib_sha=$(git -C "$repo_dir" rev-parse "$ib" 2>/dev/null)

    while IFS=$'\t' read -r key br who rrepo; do
      [ -n "$key" ] || continue
      { [ -z "$br" ] || [ "$br" = "$ib" ]; } && continue

      # Only the checkout a row was opened in can say anything true about its
      # branch. Anywhere else that branch is simply absent, which the rules
      # below read as "gone" and cancel - a live ticket in another repo killed
      # by a session start over here. The .repo field was written on every row
      # from the start and read by nothing until now.
      { [ -n "$rrepo" ] && [ "$rrepo" != "$here" ]; } && continue

      pr_state=""
      while IFS=$'\t' read -r p_br p_state; do
        [ "$p_br" = "$br" ] && { pr_state="$p_state"; break; }
      done <<< "$pr_map"

      # No `PR` property is written here. The tracker links pull requests to the
      # ticket itself and has its own verb for listing them, so a property
      # holding the same URL was a second copy of that link, going stale on its
      # own the moment the PR moved.

      merged=0
      [ "$pr_state" = "MERGED" ] && merged=1
      # Ancestry alone is not shipping. A branch with no commits points at the
      # integration tip, so `--is-ancestor` is vacuously true and the row would
      # close having shipped nothing. Require a real difference first. A merged
      # PR is checked above and stays authoritative.
      # Resolved once and reused by the branch-gone check below, which asked git
      # the same question about the same ref a second time.
      br_sha=$(git -C "$repo_dir" rev-parse --verify --quiet "$br" 2>/dev/null)
      if [ "$merged" -eq 0 ] && [ -n "$br_sha" ] && [ "$br_sha" != "$ib_sha" ]; then
        git -C "$repo_dir" merge-base --is-ancestor "$br" "$ib" 2>/dev/null && merged=1
        # Only when the local base has not already answered yes. Written as an
        # `if`, not `[ ] || git ... && merged=1`: that chain parses as
        # `(A || B) && C` and is a puzzle to read for one saved fork.
        if [ "$merged" -eq 0 ]; then
          git -C "$repo_dir" merge-base --is-ancestor "$br" "origin/$ib" 2>/dev/null && merged=1
        fi
      fi

      if [ "$merged" -eq 1 ]; then
        set_status "$key" done \
          && { logf "reconcile $key -> done (branch $br merged)"; ledger_del "$key"; }
        continue
      fi

      # Branch gone is the sole cancellation condition. "Nothing shipped" is the
      # done rule above, already evaluated - restating it here would be a second
      # copy that drifts out of sync with the rule it copies.
      if [ -z "$br_sha" ] \
         && ! git -C "$repo_dir" rev-parse --verify --quiet "origin/$br" >/dev/null 2>&1; then
        if [ "$gh_ok" -eq 1 ] && [ "$who" = "claude" ]; then
          set_status "$key" cancelled \
            && { logf "reconcile $key -> cancelled (branch $br gone)"; ledger_del "$key"; }
        else
          logf "reconcile $key: branch $br gone, not cancelling (opened_by=$who gh_ok=$gh_ok)"
        fi
      fi
    done <<< "$rows"
    ;;
  # A skill reporting to a human wants that report on the ticket too, so it
  # survives the terminal. Body on stdin rather than in argv: a summary is
  # multi-line, and argv is the one place a newline gets mangled.
  #
  # Through redact for the same reason retro is: this crosses from the machine
  # to a board other people read, and a phase transcript can quote anything the
  # working tree contains.
  #
  # Says something and closes nothing. retro, three arms up, is the same shape
  # plus a status transition and a ledger_del — that is deliberately not here.
  comment)
    state_dir
    key="${2:-}"
    [ -n "$key" ] || { logf "comment needs <key>"; exit 0; }
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 4000 || true)
    [ -n "$body" ] || { logf "comment: empty body for $key"; exit 0; }
    printf '%s' "$body" | tk_issue_comment "$key" \
      || logf "comment failed on $key"
    ;;

  *) logf "unknown subcommand: ${1:-<none>}" ;;
esac

exit 0   # unconditional: a hook must never interfere with typing
