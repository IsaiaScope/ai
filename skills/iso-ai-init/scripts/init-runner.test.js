const assert = require("node:assert");
const { test } = require("node:test");
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const { spawnSync } = require("node:child_process");

const runner = join(__dirname, "init-runner.js");

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "iso-init-runner-"));
  mkdirSync(join(root, "steps"), { recursive: true });
  writeFileSync(join(root, "steps", "global.sh"), "#!/usr/bin/env bash\necho global >> \"$ISO_STUB_LOG\"\n");
  writeFileSync(join(root, "steps", "repo.sh"), "#!/usr/bin/env bash\necho repo >> \"$ISO_STUB_LOG\"\n");
  writeFileSync(join(root, "steps", "off.sh"), "#!/usr/bin/env bash\necho off >> \"$ISO_STUB_LOG\"\n");
  writeFileSync(join(root, "steps.json"), JSON.stringify([
    { id: "global", scope: "global", enabled: true, command: ["bash", "steps/global.sh"] },
    { id: "repo", scope: "repo", enabled: true, command: ["bash", "steps/repo.sh"] },
    { id: "off", scope: "global", enabled: false, command: ["bash", "steps/off.sh"] }
  ], null, 2));
  return root;
}

test("runner executes enabled global steps and skips repo steps outside git", () => {
  const root = fixture();
  const log = join(root, "run.log");
  const r = spawnSync(process.execPath, [runner], {
    cwd: root,
    env: { ...process.env, ISO_AI_INIT_BASE: root, ISO_AI_INIT_IN_GIT_REPO: "false", ISO_STUB_LOG: log },
    encoding: "utf8"
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(readFileSync(log, "utf8"), "global\n");
  assert.match(r.stdout, /skip repo/);
});

test("runner executes repo steps when inside git", () => {
  const root = fixture();
  const log = join(root, "run.log");
  const r = spawnSync(process.execPath, [runner], {
    cwd: root,
    env: { ...process.env, ISO_AI_INIT_BASE: root, ISO_AI_INIT_IN_GIT_REPO: "true", ISO_STUB_LOG: log },
    encoding: "utf8"
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(readFileSync(log, "utf8"), "global\nrepo\n");
});
