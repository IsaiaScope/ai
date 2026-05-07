#!/bin/sh
# iso-ai-init: caveman setup script
# Run from inside the target repo.

set -e

# 1. Check + install globally (one-time, no per-repo install needed)
if command -v caveman >/dev/null 2>&1; then
    echo "caveman: already installed globally, skipping"
else
    echo "caveman: not found, installing globally..."
    bash <(curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh) --all
fi

# 2. Set global ultra mode
mkdir -p ~/.config/caveman
cp "$(dirname "$0")/caveman-config.json" ~/.config/caveman/config.json
echo "caveman: ultra mode set globally at ~/.config/caveman/config.json"

# 3. Check caveman-shrink MCP registration (global ~/.claude.json)
# Uses node instead of python3 — more reliably available in dev environments
REGISTERED=$(node -e "
const fs = require('fs'), os = require('os'), path = require('path');
const p = path.join(os.homedir(), '.claude.json');
if (!fs.existsSync(p)) { process.stdout.write('not registered'); process.exit(0); }
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const servers = {};
Object.values(d.projects || {}).forEach(proj => Object.assign(servers, proj.mcpServers || {}));
Object.assign(servers, d.mcpServers || {});
process.stdout.write('caveman-shrink' in servers ? 'registered' : 'not registered');
" 2>/dev/null || echo "not registered")

if [ "$REGISTERED" = "registered" ]; then
    echo "caveman-shrink: already registered, skipping"
else
    echo "caveman-shrink: not registered"
    echo "  To enable, add to ~/.claude.json global mcpServers:"
    echo '  "caveman-shrink": {"type":"stdio","command":"npx","args":["caveman-shrink","npx","<upstream-package>"],"env":{}}'
    echo "  No -y, no -- separator. Upstream args append after package name."
fi
