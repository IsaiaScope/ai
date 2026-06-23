const assert = require("node:assert");
const { test } = require("node:test");
const {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  symlinkSync,
  lstatSync,
  readlinkSync,
  readdirSync,
} = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const {
  SUPPORTED_AGENTS,
  scanSkills,
  localSkillCatalog,
  syncManifest,
  materializePlugin,
} = require("./skills-manifest");

function fixtureRepo() {
  const root = mkdtempSync(join(tmpdir(), "iso-manifest-"));
  const skills = join(root, "skills");
  for (const name of ["beta", "alpha"]) {
    mkdirSync(join(skills, name), { recursive: true });
    writeFileSync(join(skills, name, "SKILL.md"), `# ${name}\n`);
  }
  // a directory WITHOUT SKILL.md must be ignored
  mkdirSync(join(skills, "draft"), { recursive: true });
  return root;
}

test("scanSkills returns sorted dirs that contain SKILL.md", () => {
  const root = fixtureRepo();
  assert.deepStrictEqual(scanSkills(join(root, "skills")), ["alpha", "beta"]);
});

test("localSkillCatalog targets every supported agent", () => {
  const root = fixtureRepo();
  assert.deepStrictEqual(localSkillCatalog(join(root, "skills")), [
    { dir: "alpha", agents: SUPPORTED_AGENTS },
    { dir: "beta", agents: SUPPORTED_AGENTS },
  ]);
});

test("syncManifest writes sorted ./skills paths and preserves other keys", () => {
  const root = fixtureRepo();
  const pluginPath = join(root, "plugin.json");
  writeFileSync(pluginPath, JSON.stringify({ name: "x", skills: [] }, null, 2) + "\n");
  const first = syncManifest(pluginPath, ["alpha", "beta"]);
  assert.strictEqual(first.changed, true);
  const written = JSON.parse(readFileSync(pluginPath, "utf8"));
  assert.strictEqual(written.name, "x");
  assert.deepStrictEqual(written.skills, ["./skills/alpha", "./skills/beta"]);
});

test("syncManifest is idempotent: no change on a synced manifest", () => {
  const root = fixtureRepo();
  const pluginPath = join(root, "plugin.json");
  writeFileSync(pluginPath, JSON.stringify({ name: "x", skills: [] }, null, 2) + "\n");
  syncManifest(pluginPath, ["alpha", "beta"]);
  const second = syncManifest(pluginPath, ["alpha", "beta"]);
  assert.strictEqual(second.changed, false);
});

test("materializePlugin links routed skills, prunes stale, and writes manifest", () => {
  const root = fixtureRepo();
  const pluginDir = join(root, "plugins", "isaiascope-eng");
  mkdirSync(join(pluginDir, "skills"), { recursive: true });
  mkdirSync(join(pluginDir, ".claude-plugin"), { recursive: true });
  writeFileSync(
    join(pluginDir, ".claude-plugin", "plugin.json"),
    JSON.stringify({ name: "isaiascope-eng", skills: [] }, null, 2) + "\n",
  );
  // a stale entry no longer routed here
  symlinkSync(join("..", "..", "..", "skills", "iso-gone"), join(pluginDir, "skills", "iso-gone"));

  const res = materializePlugin(pluginDir, ["iso-a", "iso-b"]);

  assert.strictEqual(res.changed, true);
  assert.deepStrictEqual(res.pruned, ["iso-gone"]);
  const entries = readdirSync(join(pluginDir, "skills")).sort();
  assert.deepStrictEqual(entries, ["iso-a", "iso-b"]);
  for (const name of ["iso-a", "iso-b"]) {
    const link = join(pluginDir, "skills", name);
    assert.ok(lstatSync(link).isSymbolicLink());
    assert.strictEqual(readlinkSync(link), join("..", "..", "..", "skills", name));
  }
  const manifest = JSON.parse(readFileSync(join(pluginDir, ".claude-plugin", "plugin.json"), "utf8"));
  assert.deepStrictEqual(manifest.skills, ["./skills/iso-a", "./skills/iso-b"]);
});

test("materializePlugin is idempotent: second run changes nothing", () => {
  const root = fixtureRepo();
  const pluginDir = join(root, "plugins", "isaiascope-eng");
  mkdirSync(join(pluginDir, "skills"), { recursive: true });
  mkdirSync(join(pluginDir, ".claude-plugin"), { recursive: true });
  writeFileSync(
    join(pluginDir, ".claude-plugin", "plugin.json"),
    JSON.stringify({ name: "isaiascope-eng", skills: [] }, null, 2) + "\n",
  );
  materializePlugin(pluginDir, ["iso-a"]);
  const second = materializePlugin(pluginDir, ["iso-a"]);
  assert.strictEqual(second.changed, false);
  assert.deepStrictEqual(second.pruned, []);
});
