#!/usr/bin/env bash
# Multica work tracker. Called by Claude Code hooks (prompt/reconcile/end) and
# by Claude (bind/open/done). Outbound only — nothing here starts an agent.
# ponytail: one file. Every subcommand shares redact + the ledger; splitting it
# would buy nothing but an extra sourced path to get wrong.
set -uo pipefail

STATE="${MULTICA_STATE_DIR:-$HOME/.claude/multica}"
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

session_file() { echo "$STATE/session-${1:-unknown}.json"; }
bound_issue() {
  local f; f=$(session_file "$1")
  [ -f "$f" ] && jq -r '.issue // empty' "$f" 2>/dev/null || true
}

# Fire-and-forget. --content-stdin, not --content: --content decodes \n and \\,
# which mangles any code pasted into a prompt.
comment_bg() {
  local key="$1" body="$2"
  ( printf '%s' "$body" | multica issue comment add "$key" --content-stdin >/dev/null 2>>"$LOG" \
      || logf "comment add $key failed" ) &
  disown 2>/dev/null || true
}

# --no-start is load-bearing. Without it a status write can start an agent run,
# which is the one thing this design must never do.
set_status() { multica issue status "$1" "$2" --no-start >/dev/null 2>>"$LOG"; }

# `multica auth status` prints to stderr, not stdout. A plain 2>/dev/null here
# yields an empty lead and a project owned by nobody.
current_user_name() {
  multica auth status 2>&1 >/dev/null \
    | sed -n 's/^User:[[:space:]]*\(.*\) (.*/\1/p' | head -1
}

PROJECTS_CACHE_NOTE=1   # title -> id cache; issue create takes an id, not a title.
project_id_for() {
  local name="$1" id tmp
  state_dir; [ -f "$PROJECTS" ] || echo '{}' > "$PROJECTS"
  id=$(jq -r --arg n "$name" '.[$n] // empty' "$PROJECTS" 2>/dev/null)
  [ -n "$id" ] && { echo "$id"; return 0; }
  id=$(multica project list --output json 2>/dev/null \
        | jq -r --arg n "$name" '.[]? | select(.title==$n) | .id' 2>/dev/null | head -1)
  if [ -z "$id" ]; then
    local lead pargs
    lead=$(current_user_name)
    # No --priority flag exists on project create or update (CLI 0.4.26), so a
    # new project lands at priority "none" and has to be set in the UI.
    pargs=(project create --title "$name" --icon "🤖" --status in_progress --output json)
    [ -n "$lead" ] && pargs+=(--lead "$lead")
    id=$(multica "${pargs[@]}" 2>>"$LOG" | jq -r '.id // empty' 2>/dev/null)
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
  if ! multica property list --output json 2>/dev/null \
       | jq -e --arg n "$name" '[(.properties? // .)[]? | select(.name==$n)] | length > 0' \
         >/dev/null 2>&1; then
    multica property create --name "$name" --type "$type" --icon tag --output json \
      >/dev/null 2>>"$LOG" || { logf "could not create property $name"; return 1; }
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
  id=$(multica label list --output json 2>/dev/null \
        | jq -r --arg n "$name" '(.labels? // .)[]? | select(.name==$n) | .id' 2>/dev/null | head -1)
  if [ -z "$id" ]; then
    id=$(multica label create --name "$name" --color "$(label_color_for "$name")" \
          --output json 2>>"$LOG" | jq -r '.id // empty' 2>/dev/null)
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
  local sid="$1" key="$2" who="${3:-iso}" br proj st
  [ -n "$sid" ] && [ -n "$key" ] || { logf "bind needs <session_id> <key>"; return 1; }
  br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  proj=$(project_for "$PWD")
  printf '{"issue":"%s"}' "$key" > "$(session_file "$sid")" 2>/dev/null
  ledger_put "$key" "$(jq -nc --arg r "$proj" --arg b "$br" --arg p "$proj" --arg o "$who" \
    '{repo:$r,branch:$b,project:$p,opened_by:$o}')"
  # Branch on the card, not only in the local ledger: the board should stay
  # readable without ~/.claude/multica, and from another machine.
  if [ -n "$br" ]; then
    ensure_property Branch text \
      && { multica issue property set "$key" --name Branch --value "$br" >/dev/null 2>>"$LOG" \
           || logf "branch property set failed on $key"; }
  fi

  st=$(multica issue get "$key" --output json 2>/dev/null | jq -r '.status // empty' 2>/dev/null)
  case "$st" in
    backlog|todo) set_status "$key" in_progress && logf "bind $key: $st -> in_progress" ;;
  esac
  return 0
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

  prompt)
    state_dir
    payload=$(cat 2>/dev/null || true)
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    ptext=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)
    issue=$(bound_issue "$sid")
    if [ -n "$issue" ]; then
      echo "Multica: this session is $issue."
      if [ -n "$ptext" ]; then
        comment_bg "$issue" "$(printf '%s' "$ptext" | redact | head -c 4000)"
      fi
    else
      echo "Multica: no issue bound to this session. If this turn is trackable work (code changed, plan or spec written, branch created, deploy, config change, decision recorded), bind or open a row with the iso-multica-tracking skill; if it is a question, do nothing."
    fi
    ;;

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

  open)
    state_dir
    sid="${2:-}"; title="${3:-}"; parent=""; scope=""; priority=""; stage=""; agent=claude
    shift 3 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --scope)  scope="$scope ${2:-}"; shift 2 ;;
        --parent)   parent="${2:-}"; shift 2 ;;
        --priority) priority="${2:-}"; shift 2 ;;
        --stage)    stage="${2:-}"; shift 2 ;;
        --agent)    agent="${2:-}"; shift 2 ;;
        *) logf "open: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$title" ]; then logf "open needs <session_id> <title>"; exit 0; fi
    if [ -n "$stage" ]; then
      case "$stage" in
        ''|*[!0-9]*|0) logf "open: --stage must be a positive integer, got '$stage'"; stage="" ;;
      esac
      if [ -n "$stage" ] && [ -z "$parent" ]; then
        logf "open: --stage without --parent has no effect, dropping"; stage=""
      fi
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
    desc=""
    [ -t 0 ] || desc=$(cat 2>/dev/null || true)
    desc=$(printf '%s' "$desc" | redact | head -c 8000)

    # Resume block, appended after redaction so the command is never mangled.
    # The script already knows the session id, so this cannot be forgotten - and
    # a session uuid survives redact because its dashes break the hex run.
    # Only when claude is doing the work. --agent codex means the work happens in
    # a session this command cannot reach, and a resume line that resumes nothing
    # is worse than none - it reads as an offer.
    if [ "$agent" = "claude" ]; then
      resume=$(printf '**Resume this session:**\n\n```bash\nclaude --resume %s --dangerously-skip-permissions\n```' "$sid")
      if [ -n "$desc" ]; then
        desc=$(printf '%s\n\n---\n\n%s' "$desc" "$resume")
      else
        desc="$resume"
      fi
    fi

    # --status todo, not in_progress: do_bind does the promotion, and that is
    # the path that passes --no-start.
    args=(issue create --title "$safe" --project "$pid" --status todo \
          --priority "$priority" --output json)
    [ -n "$parent" ] && args+=(--parent "$parent")
    [ -n "$stage" ] && args+=(--stage "$stage")
    # Assignee is the authenticated human, so this cannot enqueue an agent run;
    # the status promotion in do_bind passes --no-start for the same reason.
    who=$(current_user_name); [ -n "$who" ] && args+=(--assignee "$who")
    if [ -n "$desc" ]; then
      key=$(printf '%s' "$desc" | multica "${args[@]}" --description-stdin 2>>"$LOG" \
              | jq -r '.identifier // .key // .id // empty' 2>/dev/null)
    else
      key=$(multica "${args[@]}" 2>>"$LOG" \
              | jq -r '.identifier // .key // .id // empty' 2>/dev/null)
    fi
    if [ -z "$key" ]; then logf "open failed for: $safe"; exit 0; fi

    # Scope label, best-effort: a missing label is cosmetic, not a reason to
    # leave the row unbound. The repo is already the project, so labelling by
    # repo would just restate it.
    for sc in $valid_scopes; do
      lid=$(label_id_for "$sc") && [ -n "$lid" ] \
        && { multica issue label add "$key" "$lid" >/dev/null 2>>"$LOG" \
             || logf "label add $key $sc failed"; }
    done

    do_bind "$sid" "$key" claude
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
          && multica issue property set "$key" --name PR --value "$pr_url" >/dev/null 2>>"$LOG" \
          && { ledger_put "$key" "$(printf '%s' "$row" | jq -c --arg u "$pr_url" '.pr=$u' 2>/dev/null)"
               row=$(ledger_get "$key")
               logf "reconcile $key: PR $pr_url recorded"; }
      fi

      merged=0
      [ "$pr_state" = "MERGED" ] && merged=1
      if [ "$merged" -eq 0 ] && git -C "$repo_dir" rev-parse --verify --quiet "$br" >/dev/null 2>&1; then
        git -C "$repo_dir" merge-base --is-ancestor "$br" "$ib" 2>/dev/null && merged=1
        git -C "$repo_dir" merge-base --is-ancestor "$br" "origin/$ib" 2>/dev/null && merged=1
      fi

      if [ "$merged" -eq 1 ]; then
        set_status "$key" done \
          && { logf "reconcile $key -> done (branch $br merged)"; ledger_del "$key"; }
        continue
      fi

      if [ "$pr_state" = "OPEN" ]; then
        cur=$(multica issue get "$key" --output json 2>/dev/null | jq -r '.status // empty' 2>/dev/null)
        [ "$cur" = "in_progress" ] && set_status "$key" in_review \
          && logf "reconcile $key -> in_review (PR open)"
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
