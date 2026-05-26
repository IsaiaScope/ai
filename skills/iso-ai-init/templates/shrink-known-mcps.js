#!/usr/bin/env node
/*
 * iso-ai-init: wrap high-value MCP servers with caveman-shrink — GLOBAL step.
 *
 * caveman-shrink is a stdio proxy: it spawns the upstream MCP as a child process
 * and compresses the responses flowing back to Claude. So an MCP is shrinkable
 * iff it is launched over stdio. Whether a given MCP is stdio or remote/HTTP is
 * a per-MACHINE fact, not a property of the vendor — someone may run Notion or
 * Figma locally over stdio while someone else uses the hosted HTTP endpoint.
 *
 * Therefore this script makes NO assumptions about any MCP's transport. It
 * carries an ALLOWLIST of *names worth shrinking* and, for each, decides purely
 * from what is actually configured on THIS machine:
 *
 *   present as stdio (claude.json)        -> wrap it in place (preserves path/env)
 *   present as stdio via an enabled plugin -> disable the plugin copy + add a
 *                                             wrapped entry from the plugin's
 *                                             own launch command
 *   present but remote/HTTP                -> skip (cannot proxy a URL)
 *   already shrunk                         -> skip
 *   absent                                 -> skip (never installs anything)
 *
 * Add a name to ALLOWLIST to make it a shrink candidate everywhere. No transport
 * or upstream-command needs to be hardcoded — both are discovered at runtime.
 *
 * Fully idempotent. Backs up ~/.claude.json + ~/.claude/settings.json before any
 * write. Makes no changes (and exits 0) if caveman-shrink is not installed.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");

const SH = "caveman-shrink";
const CLAUDE_JSON = path.join(os.homedir(), ".claude.json");
const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const PLUGIN_DIRS = [
  path.join(os.homedir(), ".claude", "plugins", "marketplaces"),
  path.join(os.homedir(), ".claude", "plugins", "cache"),
];

// Names worth shrinking (verbose, token-heavy MCPs). Transport is NOT assumed —
// each is shrunk only if it is actually present AND stdio on this machine.
const ALLOWLIST = [
  "open-design",
  "context7",
  "playwright",
  "figma",
  "notion",
  "atlassian",
  "wiki",
];

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; }
}
function backup(p) {
  if (!fs.existsSync(p)) return;
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  fs.copyFileSync(p, `${p}.bak.${ts}`);
}
function isStdio(e) { return e && e.command && e.type !== "http" && !e.url; }
// Wrapped entry = `npx [-y] caveman-shrink <upstream…>`. Tolerate a leading
// `-y` (we add it when wrapping; older entries may omit it) so detection — and
// thus idempotency — holds either way.
function isWrapped(e) {
  if (!e || e.command !== "npx" || !Array.isArray(e.args)) return false;
  return e.args.filter(x => x !== "-y")[0] === SH;
}

// Precondition: caveman-shrink must be resolvable, else wrapping writes entries
// that fail at MCP launch. Installed globally by `caveman --all` (Caveman step).
function shrinkAvailable() {
  try { execSync(`command -v ${SH}`, { stdio: "ignore", shell: "/bin/sh" }); return true; } catch {}
  try { execSync(`npx --no-install ${SH} --version`, { stdio: "ignore" }); return true; } catch {}
  return false;
}

// Best-effort: find how an enabled plugin launches a given MCP, by scanning the
// plugin .mcp.json files. Returns the raw server config (with command/args/type)
// or null. No vendor knowledge hardcoded — read from whatever is installed.
function findPluginServer(name) {
  const files = [];
  const walk = (dir, depth) => {
    if (depth > 5) return;
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const fp = path.join(dir, e.name);
      if (e.isDirectory()) walk(fp, depth + 1);
      else if (e.name === ".mcp.json" || e.name === "mcp.json") files.push(fp);
    }
  };
  for (const d of PLUGIN_DIRS) walk(d, 0);
  for (const f of files) {
    const j = readJson(f);
    if (!j) continue;
    // Plugin .mcp.json comes in two shapes in the wild: nested under
    // `mcpServers` (figma, atlassian: `{mcpServers:{<name>:{…}}}`) and bare
    // top-level (github, context7, playwright: `{<name>:{command|url…}}`).
    // Only the nested form was handled before, so plugin-provided stdio MCPs
    // that use the bare form were never discovered → Case B silently skipped
    // them. Accept either; for the bare form require a server-looking object.
    const nested = j.mcpServers && j.mcpServers[name];
    const bare = j[name] && typeof j[name] === "object" &&
                 (j[name].command || j[name].url) ? j[name] : null;
    const srv = nested || bare;
    if (srv) return srv;
  }
  return null;
}

if (!shrinkAvailable()) {
  console.log(`shrink: ${SH} not found on PATH — skipping (run the caveman step first). No changes made.`);
  process.exit(0);
}

const claude = readJson(CLAUDE_JSON);
if (!claude) { console.log("shrink: ~/.claude.json not found or unreadable — skipping"); process.exit(0); }
claude.mcpServers = claude.mcpServers || {};
const settings = readJson(SETTINGS) || {};
settings.enabledPlugins = settings.enabledPlugins || {};

let claudeDirty = false, settingsDirty = false;
const pruned = [];

// A "bare" caveman-shrink entry is the proxy registered with NO upstream to wrap
// (e.g. `npx -y caveman-shrink`) — what `caveman --with-mcp-shrink` adds. It does
// nothing useful (proxies nothing) and clutters config. Our real value is the
// wrapped entries (caveman-shrink + an upstream). Prune the bare ones wherever
// they appear (top-level and per-project), keeping wrapped entries untouched.
function isBareShrink(e) {
  if (!e || e.command !== "npx" || !Array.isArray(e.args)) return false;
  const a = e.args.filter(x => x !== "-y");
  return a.length === 1 && a[0] === SH; // only "caveman-shrink", no upstream after
}
function pruneBare(servers, scope) {
  if (!servers) return;
  for (const [k, v] of Object.entries(servers)) {
    if (isBareShrink(v)) { delete servers[k]; pruned.push(`${k}${scope}`); claudeDirty = true; }
  }
}
pruneBare(claude.mcpServers, "");
for (const [proj, v] of Object.entries(claude.projects || {})) pruneBare(v.mcpServers, ` [${proj}]`);

// Retrofit: wrapped entries created before the `-y` fix launch as `npx
// caveman-shrink …` (no `-y`). If npx ever has to resolve caveman-shrink from
// the registry it prompts, and an MCP launched by Claude Code has no TTY to
// answer → startup hang. Prepend `-y` to existing wraps that lack it so every
// wrapped entry is non-interactive. Idempotent (skips entries that already have
// it). Bare entries are gone by now (pruned above), so this only touches real
// wraps. Runs over top-level and per-project servers.
const retrofitted = [];
function retrofitY(servers, scope) {
  if (!servers) return;
  for (const [k, v] of Object.entries(servers)) {
    if (isWrapped(v) && v.args[0] !== "-y") {
      v.args = ["-y", ...v.args]; retrofitted.push(`${k}${scope}`); claudeDirty = true;
    }
  }
}
retrofitY(claude.mcpServers, "");
for (const [proj, v] of Object.entries(claude.projects || {})) retrofitY(v.mcpServers, ` [${proj}]`);

// An allowlisted name is "already shrunk" if any wrapped entry carries its name
// or its launch package in args.
function alreadyShrunk(name, pluginSrv) {
  const probe = pluginSrv && Array.isArray(pluginSrv.args)
    ? (pluginSrv.args.find(a => /@|\//.test(a)) || "")
    : "";
  // Match `name` on a TOKEN boundary, not a raw substring: short names (wiki,
  // notion, figma) would otherwise false-positive against any unrelated wrapped
  // entry that merely contains those letters (e.g. "@acme/wiki-export" → "wiki"),
  // wrongly skipping the real server. Hyphens/@/ count as boundaries, so
  // "context7" still matches "mcp-context7-server" but "wiki" won't match
  // "mediawiki". Metachars in the name are escaped defensively.
  const nameRe = new RegExp(`\\b${name.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`);
  for (const [k, v] of Object.entries(claude.mcpServers)) {
    if (!isWrapped(v)) continue;
    const hay = (k + " " + (v.args || []).join(" ")).toLowerCase();
    if (k === name || nameRe.test(hay) || (probe && hay.includes(probe))) return true;
  }
  return false;
}

// Find which enabledPlugins key (if any) owns this MCP name. Plugin keys look
// like "<plugin>@<marketplace>"; match on the plugin segment containing name.
function enabledPluginKeyFor(name) {
  for (const [k, on] of Object.entries(settings.enabledPlugins)) {
    if (on !== true) continue;
    const plugin = k.split("@")[0].toLowerCase();
    if (plugin === name.toLowerCase() || plugin.includes(name.toLowerCase())) return k;
  }
  return null;
}

// Changes (wraps) are reported verbatim; non-actionable outcomes are tallied by
// reason and printed as a single compact line, so a broad allowlist stays quiet.
const changes = [];
const skips = { "already shrunk": [], "remote/HTTP": [], "not present": [], other: [] };
const skip = (reason, name) => (skips[reason] || skips.other).push(name);

for (const name of ALLOWLIST) {
  const entry = claude.mcpServers[name];
  const pluginSrv = entry ? null : findPluginServer(name);

  if (alreadyShrunk(name, pluginSrv)) { skip("already shrunk", name); continue; }

  // Case A — present in claude.json
  if (entry) {
    if (entry.type === "http" || entry.url) { skip("remote/HTTP", name); continue; }
    if (isWrapped(entry)) { skip("already shrunk", name); continue; }
    if (isStdio(entry)) {
      claude.mcpServers[name] = { type: "stdio", command: "npx", args: ["-y", SH, entry.command, ...(entry.args || [])], env: entry.env || {} };
      claudeDirty = true; changes.push(`✓ ${name}: wrapped in place`); continue;
    }
    skip("other", name); continue;
  }

  // Case B — provided by an enabled plugin
  const pkey = enabledPluginKeyFor(name);
  if (pkey && pluginSrv) {
    if (pluginSrv.type === "http" || pluginSrv.url) { skip("remote/HTTP", name); continue; }
    if (isStdio(pluginSrv)) {
      settings.enabledPlugins[pkey] = false; settingsDirty = true;
      claude.mcpServers[name] = { type: "stdio", command: "npx", args: ["-y", SH, pluginSrv.command, ...(pluginSrv.args || [])], env: pluginSrv.env || {} };
      claudeDirty = true; changes.push(`✓ ${name}: plugin disabled + wrapped entry added`); continue;
    }
    skip("other", name); continue;
  }

  skip("not present", name);
}

if (claudeDirty) { backup(CLAUDE_JSON); fs.writeFileSync(CLAUDE_JSON, JSON.stringify(claude, null, 2)); }
if (settingsDirty) { backup(SETTINGS); fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2)); }

if (pruned.length) console.log(`✓ pruned bare caveman-shrink entry: ${pruned.join(", ")}`);
if (retrofitted.length) console.log(`✓ added -y to existing wrap: ${retrofitted.join(", ")}`);
for (const c of changes) console.log(c);
const skipParts = Object.entries(skips)
  .filter(([, names]) => names.length)
  .map(([reason, names]) => `${names.join(", ")} (${reason})`);
if (skipParts.length) console.log(`· skipped: ${skipParts.join("; ")}`);
console.log(claudeDirty || settingsDirty ? "⚠ Restart Claude Code to load the shrink wrappers." : "No changes — nothing to shrink.");
