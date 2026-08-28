#!/usr/bin/env bash
# iso-ai-init: ponytail (code-minimalism) setup — global, both agents.
# ponytail steers the agent to write the minimum necessary code ("lazy senior
# dev": does it need to exist? is it stdlib? can it be one line?). It is a plugin
# for Claude Code + Codex; intensity (lite/full/ultra/off) lives in
# ~/.config/ponytail/config.json. We pin ultra to match caveman.
# Uses bash features; invoke with bash.

set -euo pipefail

# 1. Mode config: ultra. Idempotent — only rewrite if not already ultra.
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ponytail"
CFG="$CFG_DIR/config.json"
if [ -f "$CFG" ] && grep -q '"defaultMode"[[:space:]]*:[[:space:]]*"ultra"' "$CFG" 2>/dev/null; then
    echo "ponytail: config already ultra, skipping"
else
    mkdir -p "$CFG_DIR"
    printf '{\n  "defaultMode": "ultra"\n}\n' > "$CFG"
    echo "ponytail: wrote $CFG (defaultMode=ultra)"
fi

# 2. Claude Code plugin: marketplace add + install (user scope).
#    Gate on a "ponytail" marker in settings.json so re-runs stay quiet.
#    Run from $HOME so nothing lands in a repo.
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && grep -qi "ponytail" "$CLAUDE_SETTINGS" 2>/dev/null; then
    echo "ponytail: Claude Code plugin already installed, skipping"
elif command -v claude >/dev/null 2>&1; then
    ( cd "$HOME" \
      && claude plugin marketplace add DietrichGebert/ponytail \
      && claude plugin install ponytail@ponytail --scope user ) \
      && echo "ponytail: Claude Code plugin installed" \
      || echo "ponytail: Claude Code plugin install skipped (non-fatal)"
else
    echo "ponytail: claude CLI not found, skipping Claude wiring" >&2
fi

# 3. Codex plugin: official Codex CLI flow — register the marketplace, then add
#    the plugin (`codex plugin add`, not "install"). Run from $HOME.
#    Gate on the installed-plugin dir, NOT `codex plugin list`: that command is
#    TTY-sensitive (human listing on a terminal, different/empty when piped), so
#    grepping it under the non-TTY runner never matches -> re-installs every run.
#    The cache dir is what `codex plugin list` itself reads — dir present ==
#    installed — so it's the deterministic, cwd/env/TTY-proof marker (mirrors how
#    caveman gates on an installed artifact, not command output).
CODEX_PONYTAIL_DIR="${CODEX_HOME:-$HOME/.codex}/plugins/cache/ponytail"
if ! command -v codex >/dev/null 2>&1; then
    echo "ponytail: codex CLI not found, skipping Codex wiring" >&2
elif [ -d "$CODEX_PONYTAIL_DIR" ]; then
    echo "ponytail: Codex plugin already installed, skipping"
else
    ( cd "$HOME" \
      && codex plugin marketplace add DietrichGebert/ponytail \
      && codex plugin add ponytail@ponytail ) \
      && echo "ponytail: Codex plugin installed" \
      || echo "ponytail: Codex plugin install skipped (non-fatal)"
fi
