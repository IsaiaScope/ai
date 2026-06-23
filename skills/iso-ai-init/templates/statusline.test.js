// Regression test for templates/statusline.sh — the 🐴 ponytail segment.
//
// Guards a fixed bug: the segment used to read config.json's `defaultMode` (the
// seed default), so a runtime `/ponytail full` — which only rewrites the
// `.ponytail-active` flag, never config.json — left the statusline stale on the
// seeded mode. The fix reads `.ponytail-active`, like the caveman segment.
//
// Pure render test: feeds the script known stdin + a controlled CLAUDE_CONFIG_DIR
// (the flag dir) and XDG config (a deliberately DIFFERENT defaultMode), then
// asserts the rendered label tracks the flag, not config. No network — never skips.

const assert = require("node:assert");
const { test } = require("node:test");
const { mkdtempSync, writeFileSync, rmSync, mkdirSync, unlinkSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir, homedir } = require("node:os");
const { spawnSync } = require("node:child_process");

const script = join(__dirname, "statusline.sh");
const stdin = JSON.stringify({
  cwd: homedir(),
  context_window: { used_percentage: 40 },
  cost: { total_cost_usd: 1 },
});

// Render the statusline with flagMode written to .ponytail-active (or absent when
// null), while config.json deliberately says "ultra" — so a passing assertion
// proves the flag is the source, not config. Returns the ANSI-stripped 🐴 label
// ("ULTRA"/"FULL"/…) or "" when no segment is emitted.
function ponyLabel(flagMode) {
  const dir = mkdtempSync(join(tmpdir(), "iso-statusline-"));
  const xdg = join(dir, "xdg");
  mkdirSync(join(xdg, "ponytail"), { recursive: true });
  writeFileSync(join(xdg, "ponytail", "config.json"), '{"defaultMode":"ultra"}');
  const flag = join(dir, ".ponytail-active");
  if (flagMode === null) { try { unlinkSync(flag); } catch {} }
  else writeFileSync(flag, flagMode);

  const res = spawnSync("bash", [script], {
    input: stdin,
    encoding: "utf8",
    env: { ...process.env, CLAUDE_CONFIG_DIR: dir, XDG_CONFIG_HOME: xdg },
  });
  rmSync(dir, { recursive: true, force: true });
  assert.strictEqual(res.status, 0, `statusline.sh exited ${res.status}: ${res.stderr}`);
  const m = res.stdout.replace(/\x1b\[[0-9;]*m/g, "").match(/🐴 ([A-Za-z]+)/);
  return m ? m[1] : "";
}

test("🐴 segment tracks the .ponytail-active flag, not config.json", () => {
  // config.json is "ultra" in every case; only the flag varies.
  assert.strictEqual(ponyLabel("full"), "FULL", "runtime /ponytail full must win over seeded ultra");
  assert.strictEqual(ponyLabel("lite"), "LITE");
  assert.strictEqual(ponyLabel("ultra"), "ULTRA");
  assert.strictEqual(ponyLabel("off"), "", "off → no segment");
  assert.strictEqual(ponyLabel(null), "", "flag absent → no segment");
});
