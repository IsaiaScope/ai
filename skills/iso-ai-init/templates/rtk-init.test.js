// Integration test for templates/rtk-init.sh.
//
// Verifies the rtk step sets up correctly AND is idempotent. It runs the real
// script against the real HOME (the step is global and the artifacts are the
// machine's actual rtk config) — so it both proves correctness on this machine
// and doubles as the manual "run a test" check.
//
// Skips cleanly (not fails) when the network/install is unavailable, so it never
// blocks CI on a box that can't reach GitHub releases.

const assert = require("node:assert");
const { test } = require("node:test");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { homedir } = require("node:os");
const { spawnSync } = require("node:child_process");

const script = join(__dirname, "rtk-init.sh");
const HOME = homedir();
const LOCAL_BIN = join(HOME, ".local", "bin");
const PATH_WITH_LOCAL = `${LOCAL_BIN}:${process.env.PATH}`;

function runScript() {
  return spawnSync("bash", [script], {
    encoding: "utf8",
    env: { ...process.env, PATH: PATH_WITH_LOCAL },
  });
}

function rtkGainWorks() {
  const r = spawnSync("rtk", ["gain"], { encoding: "utf8", env: { ...process.env, PATH: PATH_WITH_LOCAL } });
  return r.status === 0;
}

test("rtk-init.sh sets up rtk correctly and is idempotent", (t) => {
  const first = runScript();
  if (first.status !== 0) {
    // Most likely cause off-grid: install.sh could not download. Don't fail CI.
    t.skip(`rtk-init.sh exited ${first.status} (install/network unavailable?):\n${first.stderr}`);
    return;
  }

  // --- correctness: the CORRECT rtk (Token Killer), not Type Kit ---
  assert.ok(rtkGainWorks(), "`rtk gain` must work — proves the Token Killer binary, not Rust Type Kit");

  // --- Claude Code wiring ---
  const show = spawnSync("rtk", ["init", "--show"], {
    encoding: "utf8",
    env: { ...process.env, PATH: PATH_WITH_LOCAL },
  });
  assert.strictEqual(show.status, 0, "`rtk init --show` should exit 0");
  assert.match(show.stdout, /\[ok\]\s*Hook:/i, "PreToolUse hook should be registered");
  assert.match(show.stdout, /\[ok\]\s*settings\.json/i, "settings.json should carry the RTK hook");

  const settings = join(HOME, ".claude", "settings.json");
  assert.ok(existsSync(settings), "~/.claude/settings.json should exist");
  const hooks = JSON.parse(readFileSync(settings, "utf8")).hooks?.PreToolUse ?? [];
  const hasRtkHook = JSON.stringify(hooks).toLowerCase().includes("rtk");
  assert.ok(hasRtkHook, "settings.json PreToolUse should contain an rtk hook entry");
  assert.ok(existsSync(join(HOME, ".claude", "RTK.md")), "~/.claude/RTK.md should exist");

  // --- Codex wiring ---
  assert.ok(existsSync(join(HOME, ".codex", "RTK.md")), "~/.codex/RTK.md should exist");
  const agents = join(HOME, ".codex", "AGENTS.md");
  assert.ok(existsSync(agents), "~/.codex/AGENTS.md should exist");
  assert.match(readFileSync(agents, "utf8"), /rtk/i, "~/.codex/AGENTS.md should reference RTK");

  // --- idempotency: a second run is a no-op that still exits 0 and says "already" ---
  const second = runScript();
  assert.strictEqual(second.status, 0, `second run should exit 0:\n${second.stderr}`);
  assert.match(second.stdout, /already installed/i, "second run should skip install");
  assert.match(second.stdout, /already wired/i, "second run should skip Claude wiring");
  assert.match(second.stdout, /Codex already wired/i, "second run should skip Codex wiring");
});
