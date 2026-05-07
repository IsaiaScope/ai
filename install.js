#!/usr/bin/env node

const { execSync } = require("child_process");
const { copyFileSync, mkdirSync } = require("fs");
const { join } = require("path");
const { homedir } = require("os");

const repoRoot = __dirname;
const home = homedir();

console.log("IsaiaScope/ai — installing...\n");

// Copy CLAUDE.md to home (always overwrite — repo is source of truth)
const src = join(repoRoot, "CLAUDE.md");
const dest = join(home, "CLAUDE.md");
copyFileSync(src, dest);
console.log(`✓ CLAUDE.md → ${dest}`);

// Copy AGENTS.md to ~/.codex/ (Codex global instructions)
const codexDir = join(home, ".codex");
mkdirSync(codexDir, { recursive: true });
copyFileSync(join(repoRoot, "AGENTS.md"), join(codexDir, "AGENTS.md"));
console.log(`✓ AGENTS.md → ${join(codexDir, "AGENTS.md")}`);

// Install skill packs
const packs = [
  "juliusbrussee/caveman",
  "safishamsi/graphify",
  "forrestchang/andrej-karpathy-skills",
  "IsaiaScope/ai",
];

for (const pack of packs) {
  console.log(`\n→ Installing ${pack}`);
  execSync(`npx skills@latest add ${pack} -g -y --agent claude-code,codex`, { stdio: "inherit" });
}

// Update all global skills to latest versions
console.log("\n→ Updating all global skills");
execSync("npx skills@latest update -g -y --agent claude-code,codex", { stdio: "inherit" });

console.log("\n✓ Done.");
