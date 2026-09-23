#!/usr/bin/env sh
#
# preflight-gate.sh — decide which iso-ai-init steps may run in this directory.
#
# Two scopes:
#   global : run anywhere, even outside a git repo (caveman, MCP shrink).
#   repo   : run ONLY inside a git working tree (graphify, and future repo-scoped
#            steps). Outside a repo they are skipped, not failed.
#
# The skill sources/reads this first. It prints `IN_GIT_REPO=true|false` as the
# first line (machine-readable) followed by a human-readable plan. Add future
# repo-scoped steps to the plan below so the gate stays the single source of
# truth for what is repo- vs globally-scoped.

# node is a hard, global dependency: caveman installs via npm, and both the MCP
# shrink and statusline-merge steps are node scripts. Fail fast and clearly here
# rather than mid-step with a cryptic error.
if ! command -v node >/dev/null 2>&1; then
  echo "✗ node not found — required by caveman install, MCP shrink, and statusline setup." >&2
  echo "  Install Node.js: https://nodejs.org  (or via nvm/fnm/volta)" >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT_REPO=true
else
  IN_GIT_REPO=false
fi

# First line: machine-readable signal for the skill to branch on.
echo "IN_GIT_REPO=${IN_GIT_REPO}"

echo "--- iso-ai-init run plan ---"
echo "[global] caveman setup            : run"
echo "[global] MCP shrink (allowlist)   : run"
if [ "$IN_GIT_REPO" = true ]; then
  echo "[repo  ] graphify wiring          : run   (inside git repo)"
else
  echo "[repo  ] graphify wiring          : SKIP  (not a git repo)"
fi
