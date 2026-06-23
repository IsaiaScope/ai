"use strict";
const { readdirSync, existsSync, readFileSync, writeFileSync } = require("fs");
const { join } = require("path");

const SUPPORTED_AGENTS = ["claude-code", "codex"];

// Plugin routing: a skill is assigned to the plugin whose prefix its directory
// name starts with. New skill → routed automatically by name; no per-skill config.
const PLUGINS = [
  {
    name: "isaiascope-eng",
    prefix: "iso-",
    category: "Engineering",
    description:
      "IsaiaScope engineering skills — plan, TDD execution, review, repo/AI init, and house-style READMEs.",
  },
  {
    name: "isaiascope-social",
    prefix: "social-",
    category: "Social",
    description:
      "IsaiaScope social skills — research-first NotebookLM prep for your next video.",
  },
];

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

// Partition skill dir names across PLUGINS by prefix.
// Returns { routes: [{ plugin, skills: [name...] }], unrouted: [name...] }.
function routeSkills(skillNames) {
  const routes = PLUGINS.map((plugin) => ({ plugin, skills: [] }));
  const unrouted = [];
  for (const name of skillNames) {
    const route = routes.find((r) => name.startsWith(r.plugin.prefix));
    if (route) route.skills.push(name);
    else unrouted.push(name);
  }
  return { routes, unrouted };
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

module.exports = {
  SUPPORTED_AGENTS,
  PLUGINS,
  scanSkills,
  localSkillCatalog,
  routeSkills,
  syncManifest,
};
