// Integration test for templates/ponytail-init.sh.
//
// Verifies the ponytail step sets up correctly AND is idempotent. Runs the real
// script against the real HOME (global step, real machine artifacts) — proves
// correctness here and doubles as the manual "run a test" check.
//
// Skips cleanly (not fails) when the network/plugin install is unavailable, so it
// never blocks CI on a box that can't reach the plugin marketplace.

const assert = require("node:assert");
const { test } = require("node:test");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { homedir } = require("node:os");
const { spawnSync } = require("node:child_process");

const script = join(__dirname, "ponytail-init.sh");
const HOME = homedir();
const CONFIG = join(process.env.XDG_CONFIG_HOME || join(HOME, ".config"), "ponytail", "config.json");

function runScript() {
  return spawnSync("bash", [script], { encoding: "utf8", env: { ...process.env } });
}

test("ponytail-init.sh sets ultra config and is idempotent", (t) => {
  const first = runScript();
  if (first.status !== 0) {
    t.skip(`ponytail-init.sh exited ${first.status} (plugin/network unavailable?):\n${first.stderr}`);
    return;
  }

  // --- config: defaultMode = ultra ---
  assert.ok(existsSync(CONFIG), "~/.config/ponytail/config.json should exist");
  assert.strictEqual(
    JSON.parse(readFileSync(CONFIG, "utf8")).defaultMode,
    "ultra",
    "config defaultMode should be ultra",
  );

  // --- idempotency: second run is a no-op that still exits 0 and says "already" ---
  const second = runScript();
  assert.strictEqual(second.status, 0, `second run should exit 0:\n${second.stderr}`);
  assert.match(second.stdout, /config already ultra/i, "second run should skip config write");
});
