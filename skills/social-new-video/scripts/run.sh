#!/usr/bin/env bash
#
# social-new-video — thin launcher.
#
# Spawns ONE agent tab (codex|claude) that runs the full new-video chain inside
# itself: social-new-notebooklm-project (research → you pick the title) →
# social-notebooklm-artifacts (scaletta + 4 infographics). Fire-and-focus: async
# spawn with --focus, no --kill — you own the tab afterward.

set -uo pipefail

AGENT="codex"                 # default agent for the spawned tab
ARTIFACT_FLAGS=""             # --script-only | --images-only (forwarded to artifacts)
NOTEBOOK_ARGS=()              # topic / youtube-url / --bounded / extra-sources

fail() { echo "social-new-video: $1" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: run.sh <topic | youtube-url...> [--agent codex|claude] [--bounded]
              [--script-only | --images-only] [extra-source ...]

  <topic|youtube-url...>     forwarded to social-new-notebooklm-project (required)
  --agent codex|claude       agent the spawned tab runs (default: codex)
  --bounded                  smaller research pass (forwarded)
  --script-only|--images-only restrict the artifact step (forwarded)
  [extra-source ...]         files/URLs added to the notebook (forwarded)
EOF
}

# --- locate iso-spawn's spawn.sh (sibling skill) -------------------------------
resolve_spawn() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # real dir of this script
  local candidates=(
    "$here/../../iso-spawn/scripts/spawn.sh"                # sibling in same skills dir
    "$HOME/.claude/skills/iso-spawn/scripts/spawn.sh"
    "$HOME/.codex/skills/iso-spawn/scripts/spawn.sh"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -f "$c" ] && { printf '%s\n' "$(cd "$(dirname "$c")" && pwd -P)/$(basename "$c")"; return 0; }
  done
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent)
        [ "$#" -ge 2 ] || { usage; fail "--agent requires codex|claude."; }
        AGENT="$2"; shift ;;
      --agent=*)
        AGENT="${1#--agent=}" ;;
      --script-only|--images-only)
        [ -n "$ARTIFACT_FLAGS" ] && fail "choose only one of --script-only or --images-only."
        ARTIFACT_FLAGS="$1" ;;
      --bounded)
        NOTEBOOK_ARGS+=("$1") ;;        # forwarded verbatim
      -h|--help)
        usage; exit 0 ;;
      *)
        NOTEBOOK_ARGS+=("$1") ;;        # topic / url / extra-source
    esac
    shift
  done

  case "$AGENT" in
    codex|claude) ;;
    *) fail "--agent must be 'codex' or 'claude' (got '$AGENT')." ;;
  esac
  [ "${#NOTEBOOK_ARGS[@]}" -ge 1 ] || { usage; fail "topic or YouTube URL required."; }
}

main() {
  parse_args "$@"

  local spawn
  spawn="$(resolve_spawn)" || fail "could not find iso-spawn/scripts/spawn.sh (is the iso-spawn skill installed?)."

  local notebook_args_str="${NOTEBOOK_ARGS[*]}"
  local artifact_clause="con le impostazioni predefinite (scaletta long+short E le 4 infografiche)"
  [ -n "$ARTIFACT_FLAGS" ] && artifact_clause="con il flag $ARTIFACT_FLAGS"

  # Prompt injected + auto-run in the spawned tab. The agent runs both skills in
  # sequence and STOPS for the interactive title pick (the user drives it here).
  local prompt
  prompt=$(cat <<EOF
Esegui in sequenza due skill per preparare un nuovo video YouTube in italiano. Lavoro tutto in questo tab.

STEP 1 — Invoca la skill "social-new-notebooklm-project" con questi argomenti: ${notebook_args_str}
Seguila per intero: ricerca, presenta le 6 opzioni di titolo in italiano e FERMATI per farmi scegliere il titolo (rispondo io qui con un numero 1-6 o un titolo mio). Poi crea il notebook e aggiungi tutte le fonti. NON saltare la scelta del titolo.

STEP 2 — Solo dopo che il notebook è creato e popolato, invoca la skill "social-notebooklm-artifacts" ${artifact_clause} per generare gli asset dal notebook appena creato. Il notebook dello step 1 è quello attivo, quindi NON serve passare un id/titolo. Le infografiche sono a consumo di quota: lascia che lo script gestisca pacing e budget.

Riporta alla fine il percorso della cartella con scaletta e immagini.
EOF
)

  echo "social-new-video: spawning $AGENT tab for: ${notebook_args_str}" >&2
  # Async + focus, no --kill: you own the tab. stdout = the TERM handle.
  "$spawn" "$AGENT" --prompt "$prompt" --focus
}

main "$@"
