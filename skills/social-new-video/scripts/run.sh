#!/usr/bin/env bash
#
# social-new-video — thin launcher.
#
# Spawns ONE agent tab (codex|claude) that runs the full new-video chain inside
# itself: social-notebooklm (research → you pick the title) →
# through to the Scaletta. Fire-and-focus: async
# spawn with --focus, no --kill — you own the tab afterward.

set -uo pipefail

AGENT="codex"                 # default agent for the spawned tab
NOTEBOOK_ARGS=()              # free-form input / --fast / extra-sources

fail() { echo "social-new-video: $1" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: run.sh <topic | youtube-url...> [--agent codex|claude] [--fast]
              [extra-source ...]

  <topic|youtube-url...>     forwarded to social-notebooklm (required)
  --agent codex|claude       agent the spawned tab runs (default: codex)
  --fast                  fast research mode instead of deep (forwarded)
  [extra-source ...]         files/URLs added to the notebook (forwarded)
EOF
}

# --- locate iso-spawn's spawn.sh (sibling skill) -------------------------------
# The same upward walk iso-config's sibling.sh does, inlined rather than sourced:
# that library lives in the isaiascope-eng plugin and this skill ships in
# isaiascope-social, so sourcing it would turn a missing eng plugin into a hard
# crash instead of the "install iso-spawn" message below.
#
# Walking beats a $HOME candidate list, which is right in exactly one of the
# install topologies: repo checkout, ~/.claude|~/.codex symlink, ~/.agents pack.
# The marketplace clone puts the two plugins in separate trees, so it needs the
# explicit glob.
resolve_spawn() {
  local here candidate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # real dir of this script
  while [ "$here" != "/" ]; do
    candidate="$here/../iso-spawn/scripts/spawn.sh"
    [ -f "$candidate" ] \
      && { printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)/spawn.sh"; return 0; }
    here="$(dirname "$here")"
  done
  for candidate in "$HOME"/.claude/plugins/marketplaces/*/skills/iso-spawn/scripts/spawn.sh; do
    [ -f "$candidate" ] \
      && { printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)/spawn.sh"; return 0; }
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
      --fast)
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

  # Prompt injected + auto-run in the spawned tab. The agent runs both skills in
  # sequence and STOPS for the interactive title pick (the user drives it here).
  local prompt
  prompt=$(cat <<EOF
Prepara un nuovo video YouTube in italiano. Lavoro tutto in questo tab.

Invoca la skill "social-notebooklm" con questi argomenti: ${notebook_args_str}

Seguila per intero. Fa tutto da sola: crea il notebook, aggiunge le fonti dagli URL, lancia la deep research nativa, propone cinque titoli e genera le scalette long e short, già umanizzate e verificate contro la bozza (il lint controlla che la riscrittura non abbia perso una spiegazione).

Due cose richiedono me:
1. La scelta del titolo fra i cinque proposti — fermati e chiedimelo qui.
2. Un eventuale fallimento del lint della Scala: se un HOOK apre su un termine tecnico nudo, riscrivilo e rilancia.

Riporta alla fine il percorso della cartella con le scalette.
EOF
)

  echo "social-new-video: spawning $AGENT tab for: ${notebook_args_str}" >&2
  # Async + focus, no --kill: you own the tab. stdout = the TERM handle.
  "$spawn" "$AGENT" --prompt "$prompt" --focus
}

main "$@"
