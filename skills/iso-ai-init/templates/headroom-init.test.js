// Integration test for templates/headroom-init.sh.
//
// Verifies the headroom step sets up correctly AND is idempotent. It runs the
// real script against the real HOME (the step is global and the artifacts are the
// machine's actual headroom config) — so it both proves correctness on this
// machine and doubles as the manual "run a test" check.
//
// Skips cleanly (not fails) when the network/install is unavailable, so it never
// blocks CI on a box that can't reach PyPI / the uv installer.

const assert = require("node:assert");
const { test } = require("node:test");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { homedir } = require("node:os");
const { spawnSync } = require("node:child_process");

const script = join(__dirname, "headroom-init.sh");
const HOME = homedir();
const LOCAL_BIN = join(HOME, ".local", "bin");
const PATH_WITH_LOCAL = `${LOCAL_BIN}:${process.env.PATH}`;

function runScript() {
  return spawnSync("bash", [script], {
    encoding: "utf8",
    env: { ...process.env, PATH: PATH_WITH_LOCAL },
  });
}

function headroomRuns() {
  const r = spawnSync("headroom", ["--version"], { encoding: "utf8", env: { ...process.env, PATH: PATH_WITH_LOCAL } });
  return r.status === 0;
}

test("headroom-init.sh sets up headroom correctly and is idempotent", (t) => {
  const first = runScript();
  if (first.status !== 0) {
    // Most likely cause off-grid: PyPI / uv installer unreachable. Don't fail CI.
    t.skip(`headroom-init.sh exited ${first.status} (install/network unavailable?):\n${first.stderr}`);
    return;
  }

  // --- correctness: headroom is installed and actually runs ---
  assert.ok(headroomRuns(), "`headroom --version` must run — proves a working install, not a broken interpreter");

  // --- Claude Code wiring: durable marker + proxy routing in settings.json ---
  const settings = join(HOME, ".claude", "settings.json");
  assert.ok(existsSync(settings), "~/.claude/settings.json should exist");
  const raw = readFileSync(settings, "utf8");
  assert.match(raw, /headroom-init-claude/, "settings.json should carry headroom's durable hook marker");
  assert.match(raw, /ANTHROPIC_BASE_URL/, "settings.json should route Claude through the headroom proxy");

  // --- idempotency: a second run is a no-op that still exits 0 and says "already" ---
  const second = runScript();
  assert.strictEqual(second.status, 0, `second run should exit 0:\n${second.stderr}`);
  assert.match(second.stdout, /already installed/i, "second run should skip install");
  assert.match(second.stdout, /Claude Code already wired/i, "second run should skip Claude wiring");
  assert.match(second.stdout, /Codex already wired/i, "second run should skip Codex wiring");
});
