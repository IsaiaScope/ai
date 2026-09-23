#!/usr/bin/env bash
#
# graphify-init.sh — repo-scoped graphify setup (deterministic).
#
# Mirrors caveman-init.sh: the skill just runs this, no LLM assembly. Run from
# inside the target git repo. Installs/updates the graphify CLI, wires the
# /graphify skill into CLAUDE.md/AGENTS.md, installs AST auto-update git hooks,
# and gitignores the output dir. It does NOT build the graph itself — there is
# no CLI build verb; the deep/semantic build is orchestrated by the /graphify
# *skill* (LLM), which the iso-ai-init skill runs as Step 3b after this script.
#
# Idempotent: re-running is safe. Only drives the `graphify` CLI binary (which
# carries its own interpreter in its shebang) — no `python` calls, no guessing.

set -euo pipefail

# 0. Self-guard: this is a repo-scoped script (it installs git hooks). Refuse to
#    run outside a git working tree, regardless of how it was invoked. The gate
#    (preflight-gate.sh) is the primary decision point; this is belt-and-suspenders
#    so a mis-orchestration can't run `graphify hook install` in a non-repo.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "graphify: not inside a git repo — skipping repo-scoped setup. No changes made."
  exit 0
fi

# 1. Install or auto-update the graphify CLI to latest.
#    Prefer uv; auto-install uv if missing (and no pipx). uv puts graphify on PATH.
if ! command -v uv >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
  echo "graphify: uv not found — installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if command -v uv >/dev/null 2>&1; then
  uv tool install --upgrade graphifyy -q 2>&1 | tail -1 || true
  echo "graphify: installed/updated via uv"
elif command -v pipx >/dev/null 2>&1; then
  pipx install graphifyy >/dev/null 2>&1 || pipx upgrade graphifyy >/dev/null 2>&1 || true
  echo "graphify: installed/updated via pipx"
else
  echo "✗ uv install failed and pipx unavailable — cannot install graphify." >&2
  echo "  Install uv manually: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

if ! command -v graphify >/dev/null 2>&1; then
  echo "✗ graphify still not on PATH after install. Check ~/.local/bin is on PATH." >&2
  exit 1
fi

# 2. Native always-on integration (graphify's officially recommended setup),
#    repo-scoped via --project. Writes a "## graphify" section into CLAUDE.md /
#    AGENTS.md telling the agent to prefer `graphify query "<q>"` for codebase
#    questions over grepping raw files. On Claude Code it also installs a
#    PreToolUse *query-nudge* hook in .claude/settings.json — it fires ONLY
#    before grep/find/rg-style Bash calls and, if graphify-out/graph.json
#    exists, echoes a one-line suggestion to query the graph instead. It is
#    read-only: no rebuild, no git, nothing destructive — categorically unlike a
#    commit/husky hook. The portable guidance (CLAUDE.md/AGENTS.md "## graphify"
#    section, .claude/settings.json query-nudge) is version-controlled; the
#    regenerated/machine-specific wiring (skill copies, .codex/hooks.json) is
#    gitignored in step 4.
#    Run install UNCONDITIONALLY — no grep guard. Two reasons: (a) graphify's own
#    install is self-idempotent on the doc section (re-running does NOT duplicate
#    the "## graphify" block — verified), so a guard buys nothing; (b) a guard
#    keyed on the COMMITTED doc section would, on a fresh clone, see the section
#    already present and skip — but the clone is MISSING the gitignored wiring
#    (.claude/skills/graphify/, .agents/skills/graphify/, .codex/hooks.json),
#    which install also regenerates. Guarding on the doc would leave the /graphify
#    skill copy + codex hook uninstalled. So always run; install repairs the
#    machine-local wiring every time without touching the already-present docs.
graphify claude install --project >/dev/null 2>&1 \
  && echo "graphify: wired into CLAUDE.md (+ query-nudge hook, skill copy)" \
  || echo "graphify: claude install failed (non-fatal)"
graphify codex install --project >/dev/null 2>&1 \
  && echo "graphify: wired into AGENTS.md (+ codex hook, skill copy)" \
  || echo "graphify: codex install failed (non-fatal)"

# 2b. Build-quality default: graphify's own "## graphify" section documents how
#     to *query* the graph but not how to *build* it. Inject one rule so every
#     full build aims for the most complete knowledge outcome — `--mode deep`
#     (richest semantic + INFERRED edges). Incremental `graphify update .` stays
#     AST-only and is unaffected. Inserted right under the "## graphify" heading.
#     Idempotent via the rule's substring.
RULE='- When building or rebuilding the full graph (`/graphify`, a bare path, or a whole-tree rebuild), always use `--mode deep` for the most complete knowledge outcome — richest semantic + INFERRED edges. The auto-update git hook and `graphify update .` are AST-only (fast, no LLM) and do NOT refresh semantic edges — so the graph drifts toward code-structure-only between full builds. Re-run `/graphify --mode deep` periodically (and after large doc/concept changes) to restore the deep semantic graph.'
inject_build_rule() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q "## graphify" "$file" || return 0          # only where the section exists
  grep -qF -- '--mode deep' "$file" && return 0       # already injected
  RULE="$RULE" awk '
    {print}
    /^## graphify[[:space:]]*$/ && !done {print ""; print ENVIRON["RULE"]; done=1}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  # Fail loud on silent miss: the grep guard above saw a "## graphify" section,
  # so the awk matcher must have injected. If it didn't, the heading format
  # graphify writes has drifted (e.g. capitalized or a different #-depth) and the
  # deep-mode default silently lapsed. Warn instead of hard-failing (graphify
  # wiring is non-fatal elsewhere too).
  if ! grep -qF -- '--mode deep' "$file"; then
    echo "⚠ graphify: '## graphify' heading found in $file but deep-mode rule was not injected — heading format may have changed; add the rule manually." >&2
    return 0
  fi
  echo "graphify: build-quality rule (deep mode) added to $file"
}
inject_build_rule CLAUDE.md
inject_build_rule AGENTS.md

# 3. Auto-update: install native git hooks (post-commit + post-checkout) that
#    rebuild the graph via AST on each commit/checkout. No LLM, no husky — these
#    are plain .git/hooks scripts. Doc/concept (LLM) changes still need a manual
#    /graphify --update; the hook only refreshes the code graph. Idempotent.
if graphify hook status 2>/dev/null | grep -q "post-commit: installed"; then
  echo "graphify: auto-update git hooks already installed"
else
  graphify hook install >/dev/null 2>&1 \
    && echo "graphify: auto-update git hooks installed (post-commit/post-checkout, AST rebuild)" \
    || echo "graphify: hook install failed (non-fatal)"
fi

# 4. Gitignore graphify artifacts. Four kinds:
#    - graphify-out/        : the graph output dir.
#    - /.graphify_*.json    : transient pipeline scratch (detect/ast/analysis)
#                             that the build can drop in the repo ROOT (cwd),
#                             where graphify-out/ ignore doesn't reach → noise
#                             in `git status`. Root-anchored (leading `/`) so it
#                             never matches a `.graphify_version` inside the skill
#                             copies. Idempotent (exact-line match).
#    - {.claude,.agents}/skills/graphify/ : the per-repo skill COPIES graphify
#                             drops. Regenerated on every init, drift between
#                             graphify versions, and the codex (.agents) copy
#                             ships a stale/buggy variant (writes the python
#                             marker into graphify-out/ but reads it from root).
#                             Machine-local + regenerated → not version-controlled.
#    - .codex/hooks.json    : the codex query-nudge hook, which graphify writes
#                             with a MACHINE-SPECIFIC absolute graphify path
#                             (e.g. /Users/<you>/.local/bin/graphify) → not
#                             portable, regenerated per machine → gitignored.
#    The portable, human-readable guidance — CLAUDE.md/AGENTS.md "## graphify"
#    section and the .claude/settings.json query-nudge hook — stays committed.
ignore_line() {
  local pat="$1" label="$2"
  if grep -qxF "$pat" .gitignore 2>/dev/null; then
    echo "graphify: $label already gitignored"
  else
    echo "$pat" >> .gitignore
    echo "graphify: added $label to .gitignore"
  fi
}
ignore_line "graphify-out/" "graphify-out/"
ignore_line "/.graphify_*.json" "root scratch (.graphify_*.json)"
ignore_line ".claude/skills/graphify/" "claude skill copy"
ignore_line ".agents/skills/graphify/" "codex skill copy"
ignore_line ".codex/hooks.json" "codex hook (machine-specific path)"

# 5. Sweep leftover root scratch. graphify drops pipeline intermediates as
#    .graphify_*.json (detect/ast/analysis/extract/labels/semantic) in the repo
#    ROOT (bare cwd) — confirmed on 0.8.18, the current/latest, after a NORMAL
#    completed deep build, not just old versions or interrupted runs. It does not
#    reliably clean them, so they linger as git-status noise (gitignored above,
#    but still on disk). This runs at every init (before the Step 3b build) to
#    clear any prior run's leftovers. Root-only glob (no graphify-out/, no
#    recursion) so it never touches a live build's scratch or the committed
#    .graphify_version files in skill copies. Safe: at init time no build is running.
shopt -s nullglob 2>/dev/null || true
swept=( ./.graphify_*.json )
if (( ${#swept[@]} )); then
  rm -f ./.graphify_*.json
  echo "graphify: swept ${#swept[@]} leftover root scratch file(s) (orphans from an interrupted/old-version run)"
fi

echo "graphify: wiring complete — graph auto-updates (AST) on commit. Deep semantic build is the next step (/graphify --mode deep, LLM)."
