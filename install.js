#!/usr/bin/env node

const { execSync } = require("child_process");
const { copyFileSync } = require("fs");
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

// Install skill packs
const packs = [
  "juliusbrussee/caveman",
  "safishamsi/graphify",
  "IsaiaScope/ai",
];

for (const pack of packs) {
  console.log(`\n→ Installing ${pack}`);
  execSync(`npx skills@latest add ${pack} -g -y`, { stdio: "inherit" });
}

// Update all global skills to latest versions
console.log("\n→ Updating all global skills");
execSync("npx skills@latest update -g -y", { stdio: "inherit" });

console.log("\n✓ Done.");
