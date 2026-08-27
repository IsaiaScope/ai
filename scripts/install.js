#!/usr/bin/env node

const { execSync } = require("child_process");
const { copyFileSync, mkdirSync, readdirSync, lstatSync, unlinkSync, symlinkSync, rmSync, existsSync, readFileSync, writeFileSync } = require("fs");
const { localSkillCatalog, routeSkills, materializePlugin } = require("./skills-manifest");
const { syncAgentHooks } = require("./agent-hooks");
const { join } = require("path");
const { homedir } = require("os");

const repoRoot = join(__dirname, "..");
const home = homedir();

console.log("IsaiaScope/ai — installing...\n");

// Copy CLAUDE.md to home (always overwrite — repo is source of truth)
const src = join(repoRoot, "config", "CLAUDE.md");
const dest = join(home, "CLAUDE.md");
copyFileSync(src, dest);
console.log(`✓ config/CLAUDE.md → ${dest}`);

// Copy AGENTS.md to ~/.codex/ (Codex global instructions)
const codexDir = join(home, ".codex");
mkdirSync(codexDir, { recursive: true });
copyFileSync(join(repoRoot, "config", "AGENTS.md"), join(codexDir, "AGENTS.md"));
console.log(`✓ config/AGENTS.md → ${join(codexDir, "AGENTS.md")}`);

// Install upstream skill packs: [pack, agents[], skill?]
// A 3rd element selects ONE skill from a multi-skill pack; omit it to install the whole pack.
// Selecting a single skill also passes --full-depth so nested skills (e.g. a pack that
// groups skills under category dirs) are found — without it the CLI only scans the repo root.
// IsaiaScope/ai is NOT here — its skills are deployed locally below for both supported agents.
const packs = [
  ["juliusbrussee/caveman",                   ["claude-code", "codex"]],
  ["safishamsi/graphify",                      ["claude-code", "codex"]],
  ["forrestchang/andrej-karpathy-skills",      ["claude-code", "codex"]],
  ["mattpocock/skills",                        ["claude-code", "codex"]],
  ["crafter-station/skills",                   ["claude-code", "codex"], "intent-layer"],
];

for (const [pack, agents, skill] of packs) {
  const agentFlags = agents.map(a => `--agent ${a}`).join(" ");
  const skillFlag = skill ? ` --skill ${skill} --full-depth` : "";
  const label = skill ? `${pack} --skill ${skill}` : pack;
  console.log(`\n→ Installing ${label} (${agents.join(", ")})`);
  execSync(`npx skills@latest add ${pack} -g -y ${agentFlags}${skillFlag}`, { stdio: "inherit" });
}

// Update upstream global skills to latest versions
console.log("\n→ Updating upstream global skills");
execSync("npx skills@latest update -g -y --agent claude-code --agent codex", { stdio: "inherit" });

// Single source of truth: the filesystem. Every skills/<name>/ with a SKILL.md is a skill,
// installed for every supported agent. No hand-maintained list to drift.
const localSkills = localSkillCatalog(join(repoRoot, "skills"));

const agentSkillsDir = {
  "claude-code": join(home, ".claude", "skills"),
  "codex":       join(home, ".codex", "skills"),
};

console.log("\n→ Linking local IsaiaScope/ai skills (claude-code, codex)");
for (const dir of Object.values(agentSkillsDir)) mkdirSync(dir, { recursive: true });

// Remove any pre-existing IsaiaScope/ai skill links from the wrong agent (cleanup from prior dual-deploy)
const isaiaSkillNames = new Set(localSkills.map(s => s.dir));
for (const [agent, dir] of Object.entries(agentSkillsDir)) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!isaiaSkillNames.has(entry.name)) continue;
    const targetAgents = localSkills.find(s => s.dir === entry.name).agents;
    if (targetAgents.includes(agent)) continue;
    const wrongLink = join(dir, entry.name);
    try {
      const stat = lstatSync(wrongLink);
      if (stat.isSymbolicLink()) unlinkSync(wrongLink);
      else rmSync(wrongLink, { recursive: true, force: true });
      console.log(`  ✗ removed wrong-agent install: ${wrongLink}`);
    } catch {}
  }
}

// Prune dangling links left by a renamed or deleted skill. A rename (say
// iso-multica-tracking -> iso-issue-tracking) otherwise leaves the old name behind
// looking installed, which makes `iso-config doctor` miscount. Only broken
// symlinks are removed — a real directory is never touched.
for (const dir of Object.values(agentSkillsDir)) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isSymbolicLink()) continue;
    const link = join(dir, entry.name);
    if (existsSync(link)) continue;          // resolves fine, leave it alone
    try { unlinkSync(link); console.log(`  ✗ pruned dangling link: ${link}`); } catch {}
  }
}

// Create or refresh symlinks for every targeted agent
for (const { dir, agents } of localSkills) {
  const src = join(repoRoot, "skills", dir);
  for (const agent of agents) {
    const target = join(agentSkillsDir[agent], dir);
    try { unlinkSync(target); } catch {}
    symlinkSync(src, target);
    console.log(`  ✓ ${dir.padEnd(28)} → ${target}`);
  }
}

// Route every skill to a marketplace plugin by prefix (see skills-manifest PLUGINS),
// then materialize each plugin: a private skills/ dir of per-skill symlinks plus a
// regenerated Claude manifest. The Codex manifest stays static (skills: "./skills/",
// a whole-dir glob over that same private dir), so it needs no per-skill list.
console.log("\n→ Syncing marketplace plugins");
const { routes, unrouted } = routeSkills(localSkills.map((s) => s.dir));
if (unrouted.length) {
  console.log(`  ⚠ unrouted (no plugin prefix matched, NOT packaged): ${unrouted.join(", ")}`);
}

for (const { plugin, skills } of routes) {
  const pluginDir = join(repoRoot, "plugins", plugin.name);
  const { changed, pruned } = materializePlugin(pluginDir, skills);
  for (const name of pruned) console.log(`  ✗ ${plugin.name}: pruned stale ${name}`);
  console.log(`  ✓ ${plugin.name.padEnd(20)} ${skills.length} skill(s)${changed ? " — manifest updated" : ""}`);
}

// The tracker's two hooks live in the agent's own settings.json, which nothing
// here used to own. When the skill was renamed the hooks kept pointing at the
// old path and their `[ -x "$S" ]` guard turned them into silent no-ops — the
// board simply stopped being reconciled, with nothing to notice it. Owning them
// here means a rename self-heals on the next install.
console.log("\n→ Syncing agent hooks");
const settingsPath = join(home, ".claude", "settings.json");
try {
  let current = {};
  if (existsSync(settingsPath)) {
    // A file we cannot parse is a file we must not rewrite: it holds hooks from
    // tools this repo does not own, and a well-meaning reformat would lose them.
    try {
      current = JSON.parse(readFileSync(settingsPath, "utf8"));
    } catch (err) {
      throw new Error(`${settingsPath} is not valid JSON (${err.message}) — leaving it untouched`);
    }
  }
  const { settings, changes } = syncAgentHooks(current);
  const serialized = JSON.stringify(settings, null, 2) + "\n";
  JSON.parse(serialized); // refuse to write anything that will not read back
  if (changes.some((c) => c.action !== "unchanged")) {
    mkdirSync(join(home, ".claude"), { recursive: true });
    writeFileSync(settingsPath, serialized);
  }
  for (const c of changes) {
    if (c.action === "unchanged") console.log(`  ✓ ${c.event.padEnd(14)} ${c.name}`);
    else if (c.action === "added") console.log(`  ✓ ${c.event.padEnd(14)} ${c.name} — added`);
    else console.log(`  ✓ ${c.event.padEnd(14)} ${c.name} — replaced: ${c.was}`);
  }
} catch (err) {
  console.log(`  ⚠ ${err.message}`);
}

// Also clean up any old IsaiaScope/ai symlinks from ~/.agents/skills/ (the universal storage skills.sh used)
const universalDir = join(home, ".agents", "skills");
try {
  for (const entry of readdirSync(universalDir, { withFileTypes: true })) {
    if (!isaiaSkillNames.has(entry.name) && entry.name !== "dispatch-to-codex") continue;
    const path = join(universalDir, entry.name);
    try {
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) unlinkSync(path);
      else rmSync(path, { recursive: true, force: true });
      console.log(`  ✗ removed stale universal install: ${path}`);
    } catch {}
  }
} catch {}

console.log("\n✓ Done.");
