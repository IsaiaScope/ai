const assert = require("node:assert");
const { test } = require("node:test");
const { syncAgentHooks, commandFor, loadHooks, HOOKS_JSON } = require("./agent-hooks");
const { readFileSync } = require("node:fs");

const HOOKS = loadHooks();

const cmdOf = (s, event) =>
  (s.hooks[event] ?? []).flatMap((g) => g.hooks ?? []).map((h) => h.command);

const ours = (s, event) => cmdOf(s, event).filter((c) => c.includes("iso-hook:"));

test("empty settings gain both hooks", () => {
  const { settings, changes } = syncAgentHooks({});
  assert.deepStrictEqual(changes.map((c) => c.action), ["added", "added"]);
  assert.strictEqual(ours(settings, "SessionStart").length, 1);
  assert.strictEqual(ours(settings, "SessionEnd").length, 1);
});

test("a second run changes nothing", () => {
  const once = syncAgentHooks({}).settings;
  const { settings, changes } = syncAgentHooks(once);
  assert.deepStrictEqual(changes.map((c) => c.action), ["unchanged", "unchanged"]);
  assert.deepStrictEqual(settings, once);
});

test("hooks belonging to other tools are left alone", () => {
  const foreign = {
    hooks: {
      SessionStart: [{ hooks: [{ type: "command", command: "~/.claude/hooks/notify.sh" }] }],
      Stop: [{ hooks: [{ type: "command", command: "headroom init hook ensure" }] }],
    },
  };
  const { settings } = syncAgentHooks(foreign);
  assert.ok(cmdOf(settings, "SessionStart").includes("~/.claude/hooks/notify.sh"));
  assert.deepStrictEqual(cmdOf(settings, "Stop"), ["headroom init hook ensure"]);
});

// The bug this module exists for: a hook installed under the old skill name.
// Matching on the path would make it invisible and append a duplicate; the
// legacy match adopts it in place and stamps the marker on.
test("a pre-marker hook at the OLD path is adopted, not duplicated", () => {
  const stale = {
    hooks: {
      SessionStart: [{
        hooks: [{
          type: "command",
          command: 'S="$HOME/.claude/skills/iso-multica-tracking/scripts/multica-session.sh"; [ -x "$S" ] && "$S" reconcile; exit 0',
          timeout: 10,
        }],
      }],
    },
  };
  const { settings, changes } = syncAgentHooks(stale);
  assert.strictEqual(ours(settings, "SessionStart").length, 1, "adopted in place, no duplicate");
  const start = changes.find((c) => c.name === "reconcile");
  assert.strictEqual(start.action, "updated");
  assert.match(start.was, /iso-multica-tracking/, "reports what it replaced");
  assert.ok(!ours(settings, "SessionStart")[0].includes("multica-session.sh"));
});

test("a pre-marker hook at the CURRENT path is adopted too", () => {
  const unmarked = {
    hooks: {
      SessionEnd: [{
        hooks: [{
          type: "command",
          command: 'S="$HOME/.claude/skills/iso-tracking/scripts/tracking.sh"; [ -x "$S" ] && "$S" end; exit 0',
        }],
      }],
    },
  };
  const { settings, changes } = syncAgentHooks(unmarked);
  assert.strictEqual(ours(settings, "SessionEnd").length, 1);
  assert.strictEqual(changes.find((c) => c.name === "end").action, "updated");
});

// Legacy adoption keys on the verb as well as the path: the two hooks share a
// script, so a path-only match would let the SessionEnd hook adopt the
// SessionStart one and leave the board without a reconciler.
test("legacy adoption does not cross the two hooks over", () => {
  const both = {
    hooks: {
      SessionStart: [{ hooks: [{ type: "command", command: 'S="$HOME/.claude/skills/iso-tracking/scripts/tracking.sh"; [ -x "$S" ] && "$S" reconcile; exit 0' }] }],
      SessionEnd: [{ hooks: [{ type: "command", command: 'S="$HOME/.claude/skills/iso-tracking/scripts/tracking.sh"; [ -x "$S" ] && "$S" end; exit 0' }] }],
    },
  };
  const { settings } = syncAgentHooks(both);
  assert.match(ours(settings, "SessionStart")[0], /iso-hook:reconcile/);
  assert.match(ours(settings, "SessionEnd")[0], /iso-hook:end/);
  assert.strictEqual(ours(settings, "SessionStart").length, 1);
  assert.strictEqual(ours(settings, "SessionEnd").length, 1);
});

test("a hand-edited marked hook is overwritten and the edit reported", () => {
  const edited = syncAgentHooks({}).settings;
  edited.hooks.SessionStart[0].hooks[0].command = "echo mine  # iso-hook:reconcile";
  const { settings, changes } = syncAgentHooks(edited);
  assert.strictEqual(changes.find((c) => c.name === "reconcile").action, "updated");
  assert.strictEqual(changes.find((c) => c.name === "reconcile").was, "echo mine  # iso-hook:reconcile");
  assert.strictEqual(ours(settings, "SessionStart")[0], commandFor(HOOKS[0]));
});

test("the input object is not mutated", () => {
  const input = { hooks: {} };
  const snapshot = JSON.stringify(input);
  syncAgentHooks(input);
  assert.strictEqual(JSON.stringify(input), snapshot);
});

// The marker must not be able to comment out the command that carries it.
test("the marker sits after exit 0, never at the front", () => {
  for (const hook of HOOKS) {
    const c = commandFor(hook);
    assert.ok(!c.trimStart().startsWith("#"), "a leading # would comment out the whole line");
    assert.ok(c.indexOf("exit 0") < c.indexOf("# iso-hook:"), "marker must follow exit 0");
  }
});

// The whole point of the shared file: doctor and install must never disagree
// about which hooks exist. A hardcoded list on either side would let install
// write three hooks while doctor checks two and still reports ready.
test("the hook list comes from the file iso-config also reads", () => {
  assert.match(HOOKS_JSON, /skills[/\\]iso-tracking[/\\]scripts[/\\]hooks\.json$/);
  const onDisk = JSON.parse(readFileSync(HOOKS_JSON, "utf8"));
  assert.deepStrictEqual(loadHooks(), onDisk);
  for (const h of onDisk) {
    for (const key of ["name", "event", "verb"]) {
      assert.ok(typeof h[key] === "string" && h[key], `${key} missing from ${JSON.stringify(h)}`);
    }
  }
});

test("a hook added to the list is installed with no code change", () => {
  const extended = [...HOOKS, { name: "audit", event: "PreCompact", verb: "audit" }];
  const { settings, changes } = syncAgentHooks({}, extended);
  assert.strictEqual(changes.length, extended.length);
  const added = settings.hooks.PreCompact.flatMap((g) => g.hooks).map((h) => h.command);
  assert.strictEqual(added.length, 1);
  assert.match(added[0], /iso-hook:audit/);
  assert.match(added[0], /"\$S" audit;/);
});

