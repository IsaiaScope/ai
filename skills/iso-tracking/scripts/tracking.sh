#!/usr/bin/env bash
# Multica work tracker. Called by Claude Code hooks (reconcile/end) and
# by Claude (bind/open/done). Outbound only — nothing here starts an agent.
# ponytail: one file. Every subcommand shares redact + the ledger; splitting it
# would buy nothing but an extra sourced path to get wrong.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

TRACKER_KIND=$(iso_config_get tracker.kind)
# The ledger belongs to the tracker that wrote it -- a swap must not leave
# rows pointing at issue keys the new board never issued. tracker.ledger is
# therefore the full path, not a parent to append the kind to: appending it
# silently relocates an existing ledger, and the transition that follows
# reports "no card for plan" against an empty file it just created.
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

state_dir() { mkdir -p "$STATE" 2>/dev/null; [ -f "$LEDGER" ] || echo '{}' > "$LEDGER" 2>/dev/null; }
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

# dev, then develop, then origin's default. NOT main by convention.
integration_branch() {
  local d="${1:-$PWD}" b
  for b in dev develop; do
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

# Reverse lookup: plan path -> card key. The ledger is keyed by issue, so this
# is a scan; it holds one row per open branch, not a history, so a scan is
# cheaper than a second index that can drift.
# Matched on basename: /iso-plan records whatever path it was given and
# /iso-write may hand back a different spelling of the same file. An exact
# string compare would silently no-op, which is the failure this replaces.
# A branch name resolves too, because /iso-push holds a branch and never a
# plan path - the ledger already stores the branch for the reconciler.
card_for_plan() {
  local plan="${1:-}" base key
  [ -n "$plan" ] || return 1
  base=${plan##*/}
  state_dir
  key=$(jq -r --arg b "$base" --arg a "$plan" \
    'to_entries[]
       | select((((.value.plan // "") | split("/") | last) == $b)
                or ((.value.branch // "") == $a))
       | .key' \
    "$LEDGER" 2>/dev/null | head -1)
  [ -n "$key" ] || return 1
  echo "$key"
  return 0
}

# One plan, one card. There is nothing to fan out to.
# A miss also goes to stderr, not just the log: the whole point of these writes
# is that the board matches reality, and a transition that quietly moved nothing
# is indistinguishable from one that worked until someone opens the board days
# later. Still returns 0 - visible, never fatal.
move_plan_card() {
  local want="$1" plan="${2:-}" key
  key=$(card_for_plan "$plan") \
    || { logf "$want: no card for plan ${plan:-<none>}"
         printf 'tracking: no card matches %s -- board not moved to %s\n' \
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

# --no-start is load-bearing. Without it a status write can start an agent run,
# which is the one thing this design must never do.
set_status() { tk_issue_status "$1" "$2"; }

current_user_name() { tk_current_user; }

PROJECTS_CACHE_NOTE=1   # title -> id cache; issue create takes an id, not a title.
project_id_for() {
  local name="$1" id tmp
  state_dir; [ -f "$PROJECTS" ] || echo '{}' > "$PROJECTS"
  id=$(jq -r --arg n "$name" '.[$n] // empty' "$PROJECTS" 2>/dev/null)
  [ -n "$id" ] && { echo "$id"; return 0; }
  id=$(tk_project_list | awk -F'\t' -v n="$name" '$2==n {print $1; exit}')
  if [ -z "$id" ]; then
    local lead pargs
    lead=$(current_user_name)
    # No --priority flag exists on project create or update (CLI 0.4.26), so a
    # new project lands at priority "none" and has to be set in the UI.
    pargs=(project create --title "$name" --icon "🤖" --status in_progress --output json)
    [ -n "$lead" ] && pargs+=(--lead "$lead")
    id=$(tk_project_create "$name" "$lead")
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
  local sid="$1" key="$2" who="${3:-iso}" plan="${4:-}" promote="${5:-1}" br proj st
  [ -n "$sid" ] && [ -n "$key" ] || { logf "bind needs <session_id> <key>"; return 1; }
  br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  proj=$(project_for "$PWD")
  printf '{"issue":"%s"}' "$key" > "$(session_file "$sid")" 2>/dev/null
  # plan is what review/blocked/progress resolve a card by; it is the only
  # identifier /iso-write holds at its own boundaries.
  ledger_put "$key" "$(jq -nc --arg r "$proj" --arg b "$br" --arg p "$proj" --arg o "$who" \
    --arg pl "$plan" '{repo:$r,branch:$b,project:$p,opened_by:$o,plan:$pl}')"
  # Branch on the card, not only in the local ledger: the board should stay
  # readable without the local ledger, and from another machine.
  if [ -n "$br" ]; then
    ensure_property Branch text \
      && { tk_issue_property "$key" Branch "$br" \
           || logf "branch property set failed on $key"; }
  fi

  # `bind` attaches a session to work already underway, so it promotes.
  # `open` does not: /iso-plan leaves the card at todo and /iso-write owns the
  # move to in_progress. Promoting here would write a status nobody asked for.
  if [ "$promote" = "1" ]; then
    st=$(tk_issue_get_status "$key")
    case "$st" in
      backlog|todo) set_status "$key" in_progress && logf "bind $key: $st -> in_progress" ;;
    esac
  fi
  return 0
}

# The card body a caller pipes in, plus the two resume blocks. Shared by `open`
# and `replan` so a replanned card is shaped exactly like a fresh one - a card
# whose footer depends on which verb last touched it is a card you have to read
# twice. $1 session id, $2 agent kind, $3 plan path (may be empty).
# Body on stdin; prints the finished description.
card_body() {
  local sid="$1" agent="$2" plan="${3:-}" desc="" resume
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
    resume=$(printf '**Resume this session:**\n\n```bash\nclaude --resume %s --dangerously-skip-permissions\n```' "$sid")
    if [ -n "$plan" ]; then
      resume=$(printf '%s\n\n**Then implement the plan:**\n\n```\n/iso-write %s\n```' "$resume" "$plan")
    fi
    if [ -n "$desc" ]; then desc=$(printf '%s\n\n---\n\n%s' "$desc" "$resume")
    else desc="$resume"; fi
  fi
  printf '%s' "$desc"
}

# The live card for the branch checked out right now, or nothing. "Live" excludes
# done and cancelled: that work shipped, and a new plan against it is new work,
# not a second attempt at the old one.
card_for_branch() {
  local br key st
  br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ -n "$br" ] || return 1
  key=$(card_for_plan "$br") || return 1
  st=$(tk_issue_get_status "$key")
  case "$st" in done|cancelled) return 1 ;; esac
  printf '%s\t%s\n' "$key" "$st"
}

# Sourced by the self-check to exercise the functions in isolation. Without
# this the dispatch below runs and `exit 0` kills the sourcing shell, which
# would make the whole test file pass by printing nothing.
(return 0 2>/dev/null) && return 0

# Installed globally, so it runs in every directory Claude Code opens. Outside a
# repo there is no project to file against and no branch to reconcile, and a
# project minted for ~/Downloads is noise nobody asked for. Placed after the
# sourced-guard: the self-check sources this file and must not be gated.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

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
    key=$(card_for_plan "$plan") \
      || { logf "retro: no card for plan ${plan:-<none>}"; exit 0; }
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 4000 || true)
    if [ -n "$body" ]; then
      printf '%s' "$body" | tk_issue_comment "$key" \
        || logf "retro: comment failed on $key"
    fi
    set_status "$key" done && logf "$key -> done (retro, plan ${plan##*/})"
    ledger_del "$key"
    ;;

  # Is there a live card for the branch I am on? Prints "<KEY>\t<status>" or
  # nothing. /iso-plan asks this before writing a card: on a base branch it is
  # empty and a fresh card is opened, on a feature branch that already carries
  # work it names the card to replan against.
  card-for-branch)
    state_dir
    card_for_branch || exit 0
    ;;

  # A second plan for work already carded. The first attempt was wrong, or it
  # came back from review needing a different approach - that is the same piece
  # of work, so it is the same card. A second card would split one story across
  # two rows and leave the first sitting in_review for good.
  # Back to todo, because a new plan means nothing has been implemented yet.
  # stdin: the new card body, same shape as `open`.
  replan)
    state_dir
    sid="${2:-}"; plan=""; key=""; agent=claude
    shift 2 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan)  plan="${2:-}"; shift 2 ;;
        --key)   key="${2:-}";  shift 2 ;;
        --agent) agent="${2:-}"; shift 2 ;;
        *) logf "replan: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$plan" ]; then
      logf "replan needs <session_id> --plan <path>"; exit 0
    fi
    # An explicit --key wins: the caller was told which card by a human, and a
    # branch lookup that disagrees is the lookup being wrong, not the human.
    if [ -z "$key" ]; then
      key=$(card_for_branch | cut -f1)
      if [ -z "$key" ]; then
        logf "replan: no live card for this branch -- open a new one instead"
        printf 'tracking: no live card to replan -- opening a new one\n' >&2
        exit 0
      fi
    fi
    st=$(tk_issue_get_status "$key")
    case "$st" in
      done|cancelled)
        logf "replan: $key is $st -- that work shipped, open a new card"
        printf 'tracking: %s is %s, not replanning it\n' "$key" "$st" >&2
        exit 0 ;;
    esac
    was=$(jq -r --arg k "$key" '.[$k].plan // ""' "$LEDGER" 2>/dev/null)
    # Description replaced, not appended: the card must describe the plan being
    # worked now. The switch itself goes in a comment, which is where this
    # card's history already lives.
    desc=$(card_body "$sid" "$agent" "$plan")
    if [ -n "$desc" ]; then
      printf '%s' "$desc" | tk_issue_describe "$key" \
        || logf "replan: description update failed on $key"
    fi
    printf '🔁 **Replanned** from `%s` — superseded by `%s`. Back to `todo`; the description above is the plan now being worked.\n' \
      "${was:-<none>}" "$plan" | redact | tk_issue_comment "$key" \
      || logf "replan: comment failed on $key"
    set_status "$key" todo && logf "$key -> todo (replan, ${plan##*/}, was ${was:-<none>}, from $st)"
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
    move_plan_card "$want" "${2:-}"
    ;;

  open)
    state_dir
    sid="${2:-}"; title="${3:-}"; scope=""; priority=""; agent=claude; plan=""
    shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --scope)  scope="$scope ${2:-}"; shift 2 ;;
        --plan)   plan="${2:-}"; shift 2 ;;
        --priority) priority="${2:-}"; shift 2 ;;
        --agent)    agent="${2:-}"; shift 2 ;;
        *) logf "open: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$title" ]; then logf "open needs <session_id> <title>"; exit 0; fi
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
    desc=$(card_body "$sid" "$agent" "$plan")

    # --status todo, not in_progress: do_bind does the promotion, and that is
    # the path that passes --no-start.
    # Assignee is the authenticated human, so this cannot enqueue an agent run;
    # the status promotion in do_bind passes --no-start for the same reason.
    who=$(current_user_name)
    key=$(printf '%s' "$desc" | tk_issue_create "$pid" todo "$safe" "$priority" "$who")
    if [ -z "$key" ]; then logf "open failed for: $safe"; exit 0; fi

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
    ib=$(integration_branch "$repo_dir")
    if [ -z "$ib" ]; then logf "reconcile: no integration branch, skipping"; exit 0; fi

    # Nothing tracked means nothing to reconcile. Checked before gh, because an
    # empty ledger is the common case on session start and gh costs ~0.5s.
    [ "$(jq -r 'keys|length' "$LEDGER" 2>/dev/null || echo 0)" = "0" ] && exit 0

    # gh is the authoritative merge signal. This repo rebases onto dev before
    # merging, so ancestry alone cannot tell a rebase-merged branch from an
    # abandoned one. Without gh, cancellation is skipped for the whole run.
    prs=$(cd "$repo_dir" && gh pr list --state all --limit 200 \
            --json headRefName,state,number,url 2>/dev/null)
    gh_ok=0; [ -n "$prs" ] && gh_ok=1
    [ "$gh_ok" -eq 0 ] && logf "reconcile: gh unavailable - no cancellation this run"

    for key in $(jq -r 'keys[]' "$LEDGER" 2>/dev/null); do
      row=$(ledger_get "$key"); [ -n "$row" ] || continue
      br=$(printf '%s' "$row" | jq -r '.branch // empty' 2>/dev/null)
      who=$(printf '%s' "$row" | jq -r '.opened_by // "iso"' 2>/dev/null)
      { [ -z "$br" ] || [ "$br" = "$ib" ]; } && continue

      pr_state=$(printf '%s' "$prs" | jq -r --arg b "$br" \
        '[.[]? | select(.headRefName==$b) | .state] | first // empty' 2>/dev/null)
      pr_url=$(printf '%s' "$prs" | jq -r --arg b "$br" \
        '[.[]? | select(.headRefName==$b) | .url] | first // empty' 2>/dev/null)

      # Click-through from card to PR. Written before the merge check, because a
      # merged row is deleted from the ledger and would never get the link.
      # Recorded in the ledger so a quiet reconcile does not rewrite it each run.
      if [ -n "$pr_url" ] && [ "$pr_url" != "$(printf '%s' "$row" | jq -r '.pr // empty' 2>/dev/null)" ]; then
        ensure_property PR url \
          && tk_issue_property "$key" PR "$pr_url" \
          && { ledger_put "$key" "$(printf '%s' "$row" | jq -c --arg u "$pr_url" '.pr=$u' 2>/dev/null)"
               row=$(ledger_get "$key")
               logf "reconcile $key: PR $pr_url recorded"; }
      fi

      merged=0
      [ "$pr_state" = "MERGED" ] && merged=1
      # Ancestry alone is not shipping. A branch with no commits points at the
      # integration tip, so `--is-ancestor` is vacuously true and the row would
      # close having shipped nothing. Require a real difference first. A merged
      # PR is checked above and stays authoritative.
      if [ "$merged" -eq 0 ] && git -C "$repo_dir" rev-parse --verify --quiet "$br" >/dev/null 2>&1; then
        if [ "$(git -C "$repo_dir" rev-parse "$br" 2>/dev/null)" \
             != "$(git -C "$repo_dir" rev-parse "$ib" 2>/dev/null)" ]; then
          git -C "$repo_dir" merge-base --is-ancestor "$br" "$ib" 2>/dev/null && merged=1
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
      if ! git -C "$repo_dir" rev-parse --verify --quiet "$br" >/dev/null 2>&1 \
         && ! git -C "$repo_dir" rev-parse --verify --quiet "origin/$br" >/dev/null 2>&1; then
        if [ "$gh_ok" -eq 1 ] && [ "$who" = "claude" ]; then
          set_status "$key" cancelled \
            && { logf "reconcile $key -> cancelled (branch $br gone)"; ledger_del "$key"; }
        else
          logf "reconcile $key: branch $br gone, not cancelling (opened_by=$who gh_ok=$gh_ok)"
        fi
      fi
    done
    ;;
  *) logf "unknown subcommand: ${1:-<none>}" ;;
esac

exit 0   # unconditional: a hook must never interfere with typing
