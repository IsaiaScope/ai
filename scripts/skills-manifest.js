"use strict";
const { readdirSync, existsSync, readFileSync, writeFileSync } = require("fs");
const { join } = require("path");

const SUPPORTED_AGENTS = ["claude-code", "codex"];

// The skill set is the filesystem: every skills/<name>/ that contains a SKILL.md.
// Returns the sorted directory names.
function scanSkills(skillsRoot) {
  return readdirSync(skillsRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(skillsRoot, e.name, "SKILL.md")))
    .map((e) => e.name)
    .sort();
}

// Local Skill catalog: every repo skill targets every supported agent for now.
function localSkillCatalog(skillsRoot) {
  return scanSkills(skillsRoot).map((dir) => ({
    dir,
    agents: [...SUPPORTED_AGENTS],
  }));
}

// Rewrite ONLY plugin.json's `skills` array from the scanned names (as ./skills/<name>),
// preserving every other key. Writes only when the array actually changed.
// Returns { changed, skills }.
function syncManifest(pluginPath, skillNames) {
  const plugin = JSON.parse(readFileSync(pluginPath, "utf8"));
  const next = skillNames.map((n) => `./skills/${n}`);
  const changed = JSON.stringify(plugin.skills) !== JSON.stringify(next);
  if (changed) {
    plugin.skills = next;
    writeFileSync(pluginPath, JSON.stringify(plugin, null, 2) + "\n");
  }
  return { changed, skills: next };
}

module.exports = { SUPPORTED_AGENTS, scanSkills, localSkillCatalog, syncManifest };
