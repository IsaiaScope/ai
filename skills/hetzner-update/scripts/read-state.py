#!/usr/bin/env python3
"""Read the current version of every half of a registered app.

Resolves {alias} from the fleet, runs each version_cmd, and prints what
is actually installed. Read-only: it runs nothing from upgrade_cmd or
backup_cmd, so it is always safe to call.

    read-state.py multica
    read-state.py multica --print-cmds     # show resolved commands, run nothing
    read-state.py --list
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys

# Overridable so the refusal paths can be exercised against a fixture without
# touching the real config.
CONFIG = os.path.expanduser(
    os.environ.get("HETZNER_CONFIG_JSON", "~/.config/hetzner/hetzner.json"))

# Borrow the planner's semver parser rather than writing a second one. Two
# definitions of "which version is newer" would eventually disagree, and the
# disagreement would show up as a correct-looking plan built from the wrong
# starting point. Naive string compare is the specific trap: "0.4.9" > "0.4.19".
sys.dont_write_bytecode = True          # no __pycache__ litter in the skill dir
_spec = importlib.util.spec_from_file_location(
    "planner", os.path.join(os.path.dirname(os.path.abspath(__file__)), "plan-upgrade.py"))
_planner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_planner)


def newer(a, b):
    """True when a is a strictly newer version than b. None if either is unparseable."""
    pa, pb = _planner.parse(a), _planner.parse(b)
    if not pa or not pb:
        return None
    return _planner.key(pa) > _planner.key(pb)


def same(a, b):
    pa, pb = _planner.parse(a), _planner.parse(b)
    if not pa or not pb:
        return None
    return _planner.key(pa) == _planner.key(pb)


def load(path, what):
    if not os.path.exists(path):
        die("%s not found at %s" % (what, path))
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        die("%s is not valid JSON: line %d, %s" % (what, e.lineno, e.msg))


def die(msg):
    print(json.dumps({"error": msg}, indent=2))
    sys.exit(2)


def run(cmd, timeout=60):
    """Run a registry command. Returns (value, error) — never raises."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timed out after %ds" % timeout
    if r.returncode != 0:
        return None, (r.stderr.strip() or r.stdout.strip() or "exit %d" % r.returncode)
    out = r.stdout.strip()
    if not out:
        return None, "printed nothing"
    if "\n" in out:
        return None, "printed %d lines, expected a bare version: %r" % (len(out.splitlines()), out)
    return out, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app", nargs="?", help="key under software in hetzner.json")
    ap.add_argument("--print-cmds", action="store_true", help="show resolved commands, run nothing")
    ap.add_argument("--list", action="store_true", help="list registered apps")
    args = ap.parse_args()

    cfg = load(CONFIG, "hetzner config")
    soft = cfg.get("software", {})
    if args.list or not args.app:
        print(json.dumps({"apps": sorted(soft)}, indent=2))
        return
    if args.app not in soft:
        die("no app %r in the registry. Known: %s" % (args.app, ", ".join(sorted(soft)) or "none"))

    e = soft[args.app]
    servers = cfg.get("fleet", {}).get("servers", {})
    if e.get("server") not in servers:
        die("entry %r names server %r, which is not in the fleet. Known: %s"
            % (args.app, e.get("server"), ", ".join(sorted(servers))))
    alias = servers[e["server"]].get("ssh_alias")
    if not alias:
        die("server %r has no ssh_alias in the fleet" % e["server"])

    def resolve(cmd):
        return cmd.replace("{alias}", alias) if cmd else cmd

    halves = {
        "local": resolve(e.get("local", {}).get("version_cmd")),
        "remote": resolve(e.get("remote", {}).get("version_cmd")),
    }
    comps = [(c.get("name", "?"), resolve(c.get("version_cmd"))) for c in e.get("companions", [])]

    if args.print_cmds:
        print(json.dumps({
            "app": args.app, "alias": alias,
            "version_cmds": halves,
            "companion_cmds": {n: c for n, c in comps},
            "upgrade_cmd": resolve(e.get("remote", {}).get("upgrade_cmd")),
            "backup_cmd": resolve(e.get("backup_cmd")),
            "backup_verify_cmd": resolve(e.get("backup_verify_cmd")),
            "verify_cmd": resolve(e.get("remote", {}).get("verify_cmd")),
        }, indent=2))
        return

    out = {"app": args.app, "server": e["server"], "alias": alias,
           "repo": e.get("repo"), "pinned": e.get("pinned"),
           "self_updating": bool(e.get("local", {}).get("self_updating"))}

    for side, cmd in halves.items():
        if not cmd:
            out[side] = {"error": "no version_cmd in the registry"}
            continue
        v, err = run(cmd)
        out[side] = {"version": v} if v else {"error": err}

    out["companions"] = []
    for name, cmd in comps:
        v, err = run(cmd) if cmd else (None, "no version_cmd")
        out["companions"].append({"name": name, **({"version": v} if v else {"error": err})})

    lv = out.get("local", {}).get("version")
    rv = out.get("remote", {}).get("version")
    if lv and rv and same(lv, rv) is not None:
        if same(lv, rv):
            out["drift"] = "aligned"
            out["plan_from"] = lv
        else:
            out["drift"] = "local ahead" if newer(lv, rv) else "remote ahead"
            # Plan from whichever half is behind — that is the gap to close.
            out["plan_from"] = rv if out["drift"] == "local ahead" else lv
        if out["drift"] == "remote ahead" and out["self_updating"]:
            out["blocked"] = ("The local half is behind and self-updating, so it cannot be "
                              "pinned or forced. Ask the user to update the app. Never "
                              "downgrade the server to meet a stale client.")
    else:
        out["drift"] = "unknown — a version_cmd failed or returned an unparseable version"

    lagging = [c["name"] for c in out["companions"]
               if c.get("version") and lv and same(c["version"], lv) is False]
    if lagging:
        out["companions_lagging"] = lagging
        out["companions_note"] = ("These share the name but not the protocol. Lagging is "
                                  "harmless; do not report it as drift.")

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
