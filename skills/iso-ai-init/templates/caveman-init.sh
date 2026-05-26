#!/usr/bin/env bash
# iso-ai-init: caveman setup script (global — runs anywhere).
# Uses bash features (process substitution); invoke with bash.

set -euo pipefail

# 1. Install caveman GLOBALLY if not already set up.
#    caveman is a Claude Code *plugin*, not a PATH binary, so `command -v caveman`
#    NEVER succeeds — detect via an artifact the installer drops instead.
#    Flags: do NOT use --all. --all turns on --with-init, which writes IDE rule
#    files (.cursor/.windsurf/.clinerules/.github/AGENTS.md) into the CURRENT
#    repo — pollution. We want a global-only install:
#      --non-interactive : agent-safe, no prompts
#      --skip-skills     : skip the multi-agent `skills add` clone (writes .agents/, etc.)
#    Defaults keep --with-hooks ON (statusline/mode hooks) and --with-mcp-shrink
#    ON (installs the caveman-shrink binary our wrapped entries need); --with-init
#    stays OFF. Run from $HOME so any stray cwd-relative write cannot land in the
#    target repo.
CAVEMAN_MARK="$HOME/.claude/hooks/caveman-config.js"
if [ -f "$CAVEMAN_MARK" ] || [ -f "$HOME/.config/caveman/config.json" ]; then
    echo "caveman: already installed globally, skipping installer"
else
    echo "caveman: not found, installing globally (no repo writes)..."
    ( cd "$HOME" && bash <(curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh) --non-interactive --skip-skills )
    # Codex: install the caveman skill globally too (run from $HOME so nothing
    # lands in the repo). Non-fatal if it fails.
    ( cd "$HOME" && npx -y skills add JuliusBrussee/caveman -a codex --yes --all >/dev/null 2>&1 ) \
      && echo "caveman: codex skills installed (global)" \
      || echo "caveman: codex skills install skipped (non-fatal)"
fi

# 2. Set global ultra mode
mkdir -p ~/.config/caveman
cp "$(dirname "$0")/caveman-config.json" ~/.config/caveman/config.json
echo "caveman: ultra mode set globally at ~/.config/caveman/config.json"

# caveman-shrink ships with `caveman --all` (installed above). Wrapping specific
# MCP servers is owned by the MCP-shrink step (templates/shrink-known-mcps.js),
# which registers concrete `caveman-shrink npx <upstream>` entries from the
# allowlist — so there is nothing to register here.

# 3. Statusline — copy the command script, then SAFELY merge the statusLine key
#    into ~/.claude/settings.json. Read-modify-write via node: never clobbers
#    other keys, backs up before writing.
#
#    The merge must distinguish THREE existing-statusLine cases, because caveman's
#    own installer (--with-hooks, on by default) registers ITS OWN statusLine
#    (…/caveman-statusline.sh) during Step 1 above — so by the time we get here a
#    statusLine is ALWAYS set on a fresh caveman install. A naive "skip if set"
#    guard therefore loses to caveman's minimal bar every time (it prints only
#    "[CAVEMAN:ULTRA]" — no dir/branch/ctx/cost). Our statusline.sh already renders
#    that ULTRA suffix PLUS the rich fields, so ours strictly supersedes caveman's.
#      - already ours      -> nothing to do
#      - caveman's own      -> overwrite with ours (ULTRA suffix preserved)
#      - foreign/user's own -> respect it, leave as-is (never clobber a real custom bar)
mkdir -p ~/.claude
cp "$(dirname "$0")/statusline.sh" ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
node -e '
const fs=require("fs"),os=require("os"),path=require("path");
const p=path.join(os.homedir(),".claude","settings.json");
let d={}; try{ d=JSON.parse(fs.readFileSync(p,"utf8")); }catch{}
const cur=d.statusLine;
const curCmd = cur && typeof cur.command==="string" ? cur.command : "";
const isOurs    = curCmd.includes("statusline-command.sh");
const isCaveman = /caveman.*statusline|statusline.*caveman/i.test(curCmd);
if (isOurs){ console.log("caveman: statusLine already ours — no change"); process.exit(0); }
if (cur && !isCaveman){ console.log("caveman: a custom statusLine is set (not ours, not caveman'"'"'s) — left as-is"); process.exit(0); }
if(fs.existsSync(p)){ const ts=new Date().toISOString().replace(/[:.]/g,"-"); fs.copyFileSync(p,p+".bak."+ts); }
d.statusLine={type:"command",command:"bash ~/.claude/statusline-command.sh"};
fs.writeFileSync(p, JSON.stringify(d,null,2));
console.log(isCaveman
  ? "caveman: replaced caveman'"'"'s minimal statusLine with rich statusline-command.sh (ULTRA suffix preserved)"
  : "caveman: statusLine wired into ~/.claude/settings.json");
'
