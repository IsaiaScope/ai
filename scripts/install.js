#!/usr/bin/env node

const { execSync } = require("child_process");
const { copyFileSync, mkdirSync, readdirSync, lstatSync, unlinkSync, symlinkSync, rmSync } = require("fs");
const { localSkillCatalog, syncManifest } = require("./skills-manifest");
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

// Regenerate the marketplace manifest from the same scan (filesystem = source of truth).
const pluginPath = join(repoRoot, ".claude-plugin", "plugin.json");
const { changed } = syncManifest(pluginPath, localSkills.map((s) => s.dir));
console.log(changed
  ? `  ✓ plugin.json skills regenerated (${localSkills.length})`
  : `  ✓ plugin.json skills already in sync (${localSkills.length})`);

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
