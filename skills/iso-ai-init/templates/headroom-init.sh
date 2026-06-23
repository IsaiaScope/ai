#!/usr/bin/env bash
# iso-ai-init: headroom (AI context compression) setup — global, runs anywhere.
# headroom compresses everything the agent reads — tool output, logs, files,
# conversation — before it reaches the model (60-95% fewer tokens). It is a
# Python CLI wired into Claude Code and Codex via `headroom init` (durable hooks
# + provider routing through a local proxy on 127.0.0.1:8787). Replaces rtk:
# same goal (fewer tokens), broader layer (whole context, not just command output).
# Uses bash features; invoke with bash.

set -euo pipefail

# headroom (pipx / uv tool) lands in ~/.local/bin. Put it on PATH up front so the
# install check and the `headroom init` calls below all resolve the same binary.
LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"

# Extras = the token-SAVINGS set only (skip framework glue / voice / evals bloat).
# pytorch-mps is Apple-Silicon-only — it pulls the MPS torch backend, so gate it on
# darwin/arm64; elsewhere `ml` still works on CPU.
EXTRAS="proxy,code,mcp,ml,relevance,memory"
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    EXTRAS="${EXTRAS},pytorch-mps"
fi
PKG="headroom-ai[${EXTRAS}]"

# Correctness probe: headroom must be ON PATH *and actually run*. The second half
# matters on macOS 26, where a broken system/brew Python lets `pipx install`
# "succeed" yet the resulting `headroom` can't execute — `--version` catches it.
headroom_ok() { command -v headroom >/dev/null 2>&1 && headroom --version >/dev/null 2>&1; }

# 1. Ensure headroom is installed globally, with the savings extras.
if headroom_ok; then
    echo "headroom: already installed ($(headroom --version 2>/dev/null)), skipping install"
else
    echo "headroom: not found (or not runnable), installing globally..."
    # pipx first: isolated venv, the recommended pip-family installer (no global
    # pip pollution). On a healthy interpreter this is enough.
    if command -v pipx >/dev/null 2>&1 && pipx install "$PKG" 2>/dev/null && headroom_ok; then
        echo "headroom: installed via pipx -> $LOCAL_BIN"
    else
        # uv fallback: when the system/brew Python is broken (macOS 26 mac_ver bug),
        # uv-managed Python reports its OS correctly and runs headroom. Auto-install
        # uv if missing, pin a known-good interpreter, install as an isolated tool.
        echo "headroom: pipx route unavailable/broken, falling back to uv-managed Python..." >&2
        command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$LOCAL_BIN:$PATH"
        uv python install 3.13
        uv tool install --force --python 3.13 "$PKG"
        echo "headroom: installed via uv tool (Python 3.13) -> $LOCAL_BIN"
    fi
fi

# Post-install gate: prove headroom ended up runnable ON PATH.
export PATH="$LOCAL_BIN:$PATH"
if ! headroom_ok; then
    echo "headroom: post-install check FAILED — 'headroom --version' does not run (broken Python? not on PATH?)" >&2
    exit 1
fi

# 2. Wire headroom into Claude Code GLOBALLY (durable hooks + provider routing).
#    `init --global --memory claude` writes the proxy-keepalive hooks, sets
#    ANTHROPIC_BASE_URL to the local proxy, and enables persistent memory.
#    Gate on headroom's own settings.json marker so a second /iso-ai-init stays
#    quiet. Run from $HOME so nothing lands in a repo.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && grep -q "headroom-init-claude" "$CLAUDE_SETTINGS" 2>/dev/null; then
    echo "headroom: Claude Code already wired, skipping"
else
    ( cd "$HOME" && headroom init --global --memory claude ) \
      && echo "headroom: Claude Code wired (durable hooks + proxy routing)" \
      || echo "headroom: Claude Code wiring skipped (non-fatal)"
fi

# 3. Wire headroom into Codex GLOBALLY (durable hooks + provider routing).
#    Marker: a "headroom" reference in the global Codex config. Re-runnable either way.
if { [ -f "$HOME/.codex/config.toml" ] && grep -qi "headroom" "$HOME/.codex/config.toml" 2>/dev/null; } \
   || { [ -f "$HOME/.codex/AGENTS.md" ] && grep -qi "headroom" "$HOME/.codex/AGENTS.md" 2>/dev/null; }; then
    echo "headroom: Codex already wired, skipping"
else
    ( cd "$HOME" && headroom init --global --memory codex ) \
      && echo "headroom: Codex wired (durable hooks + proxy routing)" \
      || echo "headroom: Codex wiring skipped (non-fatal)"
fi
