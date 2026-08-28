// The two hooks this repo installs into the agent's own settings: SessionStart
// runs the tracker's reconciler, SessionEnd flushes the session row.
//
// They live in the user's settings.json alongside hooks from unrelated tools,
// so identity is a marker token, never the path. The path is exactly what a
// skill rename changes, and matching on it makes a renamed hook invisible
// rather than stale — which is how a dead reconcile hook survived a rename
// unnoticed, its own `[ -x "$S" ]` guard turning it into a silent no-op.
//
// ponytail: two entries hardcoded here rather than a config/hooks.json. Nobody
// varies them per machine; a file would cost a schema and a parse path to hold
// two constants.

const { readFileSync } = require("fs");
const { join } = require("path");

// Relative to the agent config dir, not to $HOME: Claude Code honours
// CLAUDE_CONFIG_DIR, and a hook command that hardcodes $HOME/.claude fails
// SILENTLY for anyone who moved theirs -- `[ -x "$S" ]` is simply false, so the
// hook no-ops and the board stops being updated with no error anywhere.
// iso-config's `doctor` already reads settings.json through the same override
// (config.sh:41,71); this is the write side catching up.
const SKILL_REL = "skills/iso-issue-tracking/scripts/tracking.sh";
// A shell expression, expanded by the hook shell -- not by this module.
const CONFIG_DIR = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}";

// The list lives with the skill it wires up, in a file both readers can reach:
// this module resolves it from the repo, and iso-config's `doctor` resolves the
// same file through iso_sibling, which works under all four install topologies.
// It is data, not config - nobody varies it per machine - but a hardcoded copy
// on each side would let `doctor` silently check fewer hooks than install writes,
// which is the same silent-under-checking this whole module exists to prevent.
const HOOKS_JSON = join(__dirname, "..", "skills", "iso-issue-tracking", "scripts", "hooks.json");

const loadHooks = (path = HOOKS_JSON) => JSON.parse(readFileSync(path, "utf8"));

// Matched only to adopt a hook installed before markers existed, so the first
// run after this change stamps the marker on rather than appending a duplicate.
// Never consulted to decide whether a hook is stale.
const LEGACY_PATHS = [
  "iso-multica-tracking/scripts/multica-session.sh",
  "iso-issue-tracking/scripts/tracking.sh",
];

const marker = (name) => `# iso-hook:${name}`;

// Trailing, because a leading `#` would comment out the whole one-line command.
// It sits after `exit 0` and never executes; it exists to be grepped.
const commandFor = ({ name, verb }) =>
  `S="${CONFIG_DIR}/${SKILL_REL}"; [ -x "$S" ] && "$S" ${verb}; exit 0  ${marker(name)}`;

const isOurs = (command, hook) =>
  command.includes(marker(hook.name)) ||
  LEGACY_PATHS.some((p) => command.includes(p) && command.includes(` ${hook.verb};`));

// Pure: takes a parsed settings object, returns a new one plus what changed.
// The caller owns every byte of file I/O, so a malformed write can be refused
// before it lands on a file holding nine hooks this repo does not own.
function syncAgentHooks(settings, hooks = loadHooks()) {
  const next = JSON.parse(JSON.stringify(settings ?? {}));
  next.hooks = next.hooks ?? {};
  const changes = [];

  for (const hook of hooks) {
    const want = commandFor(hook);
    next.hooks[hook.event] = next.hooks[hook.event] ?? [];
    let found = null;
    for (const group of next.hooks[hook.event]) {
      for (const entry of group.hooks ?? []) {
        if (typeof entry.command === "string" && isOurs(entry.command, hook)) {
          found = entry;
          break;
        }
      }
      if (found) break;
    }

    if (!found) {
      next.hooks[hook.event].push({ hooks: [{ type: "command", command: want, timeout: 10 }] });
      changes.push({ name: hook.name, event: hook.event, action: "added" });
    } else if (found.command !== want) {
      // Overwrite, including a hand-edit: owning the hook has to mean owning
      // it, or the drift comes back wearing a different hat. The replaced
      // command is reported so a clobber is visible rather than silent.
      const was = found.command;
      found.command = want;
      changes.push({ name: hook.name, event: hook.event, action: "updated", was });
    } else {
      changes.push({ name: hook.name, event: hook.event, action: "unchanged" });
    }
  }

  return { settings: next, changes };
}

module.exports = { HOOKS_JSON, loadHooks, SKILL_REL, syncAgentHooks, commandFor, marker };
