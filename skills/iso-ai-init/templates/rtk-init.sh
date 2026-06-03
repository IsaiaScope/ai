#!/usr/bin/env bash
# iso-ai-init: rtk (Rust Token Killer) setup — global, runs anywhere.
# rtk is a CLI proxy that filters/compresses dev-command output (git/ls/grep/…)
# before it reaches the model — 60-90% fewer tokens on common commands. It is a
# single static Rust binary (no runtime deps), wired into Claude Code via a
# PreToolUse rewrite hook and into Codex via AGENTS.md + RTK.md instruction
# injection. Different layer from caveman (which compresses prose) — complementary.
# Uses bash features; invoke with bash.

set -euo pipefail

# rtk's install.sh drops the binary in ~/.local/bin by default. Put it on PATH up
# front so both the install check and the init calls below can resolve it.
LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"

# 1. Ensure the CORRECT rtk binary is installed globally.
#    NAME-COLLISION HAZARD (per official INSTALL.md): a DIFFERENT tool — Rust Type
#    Kit (reachingforthejack/rtk) — also ships a binary named `rtk`. Both answer
#    `command -v rtk` and `rtk --version`, so neither proves we have the Token
#    Killer. The official correctness probe is `rtk gain` (Token Killer has it;
#    Type Kit does not). Gate on that, so a machine with the WRONG rtk pre-installed
#    still gets the right one. Same reason cargo uses `--git <repo>`, never
#    `cargo install rtk` (crates.io may resolve to Type Kit).
rtk_ok() { command -v rtk >/dev/null 2>&1 && rtk gain >/dev/null 2>&1; }

if rtk_ok; then
    echo "rtk: correct binary already installed ($(rtk --version 2>/dev/null)), skipping install"
else
    if command -v rtk >/dev/null 2>&1; then
        echo "rtk: a binary named 'rtk' exists but 'rtk gain' fails — likely the WRONG rtk (Rust Type Kit). Installing the correct one from rtk-ai/rtk (it wins on PATH via $LOCAL_BIN)..." >&2
    else
        echo "rtk: not found, installing globally..."
    fi
    # install.sh first: prebuilt binary, pinned dest ~/.local/bin, unambiguous repo.
    # cargo --git next: compiles from the correct repo (guaranteed Token Killer).
    # brew last: best-effort; `brew install rtk` formula name is not collision-proof,
    # so the post-install `rtk_ok` gate below is what actually guarantees correctness.
    if curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh; then
        echo "rtk: installed via install.sh -> $LOCAL_BIN"
    elif command -v cargo >/dev/null 2>&1 && cargo install --git https://github.com/rtk-ai/rtk; then
        echo "rtk: installed via cargo --git -> $HOME/.cargo/bin"
    elif command -v brew >/dev/null 2>&1 && brew install rtk; then
        echo "rtk: installed via brew"
    else
        echo "rtk: install FAILED (curl/cargo/brew all unavailable or errored)" >&2
        exit 1
    fi
fi

# Post-install correctness gate: prove we ended up with the Token Killer ON PATH.
# Catches a wrong-binary install AND a binary that landed off PATH ($LOCAL_BIN).
export PATH="$LOCAL_BIN:$PATH"
if ! rtk_ok; then
    if command -v rtk >/dev/null 2>&1; then
        echo "rtk: post-install check FAILED — 'rtk gain' does not work (wrong binary on PATH?)" >&2
    else
        echo "rtk: post-install check FAILED — not on PATH ($LOCAL_BIN missing from PATH; add it to your shell profile)" >&2
    fi
    exit 1
fi

# 2. Wire rtk into Claude Code GLOBALLY (PreToolUse rewrite hook + settings.json).
#    `--auto-patch` is REQUIRED: without it, `rtk init` prompts y/N to patch
#    settings.json and a non-interactive shell answers N — so the hook silently
#    never lands and only RTK.md is written. --auto-patch writes the hook directly.
#    Gate on a settings.json `rtk` marker so a second /iso-ai-init run stays quiet.
#    Run from $HOME so nothing lands in a repo.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && grep -qi "rtk" "$CLAUDE_SETTINGS" 2>/dev/null; then
    echo "rtk: Claude Code hook already wired, skipping"
else
    ( cd "$HOME" && rtk init -g --auto-patch ) \
      && echo "rtk: Claude Code wired (PreToolUse hook + settings.json)" \
      || echo "rtk: Claude Code wiring skipped (non-fatal)"
fi

# 3. Wire rtk into Codex GLOBALLY (AGENTS.md + RTK.md instruction injection).
#    Marker: RTK.md beside the global Codex config. Re-runnable either way.
if [ -f "$HOME/.codex/RTK.md" ] || { [ -f "$HOME/.codex/AGENTS.md" ] && grep -qi "rtk" "$HOME/.codex/AGENTS.md" 2>/dev/null; }; then
    echo "rtk: Codex already wired, skipping"
else
    ( cd "$HOME" && rtk init -g --codex ) \
      && echo "rtk: Codex wired (AGENTS.md + RTK.md)" \
      || echo "rtk: Codex wiring skipped (non-fatal)"
fi
