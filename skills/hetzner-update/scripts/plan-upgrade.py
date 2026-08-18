#!/usr/bin/env python3
"""Resolve an upgrade target from a GitHub release list.

Answers one question: given what is installed now, how far can we move without
crossing a breaking change? Prints JSON; the skill decides what to do with it.

    plan-upgrade.py --repo multica-ai/multica --current v0.4.18
    plan-upgrade.py --repo multica-ai/multica --current v0.4.18 --allow-breaking

Exit codes: 0 plan produced (may be a no-op) · 2 bad input or unusable API reply.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")

# Signals in a release body that mean "a human reads this before it ships".
#
# Deliberately NOT matching a bare "migration": a project that runs schema
# migrations automatically on boot mentions them in almost every release, so
# that word flags everything and the check stops meaning anything. Only
# migrations a person has to perform count.
BODY_SIGNALS = [
    (re.compile(r"BREAKING[ -]CHANGE", re.I), "BREAKING CHANGE in notes"),
    # Not anchored to the start of the line: changelogs generated from git log
    # put the sha first ("* a1b2c3d feat(api)!: ..."), so an anchored pattern
    # silently matches nothing on exactly the projects worth scanning.
    (re.compile(r"(?:^|\s)\w+(?:\([^)]*\))?!:", re.M), "conventional-commit '!' marker"),
    (re.compile(r"backwards?[ -]incompatible", re.I), "declared backwards-incompatible"),
    (re.compile(r"not\s+backwards?[ -]compatible", re.I), "declared not backward-compatible"),
    (re.compile(r"action\s+required", re.I), "'action required' in notes"),
    (re.compile(r"manual\s+(?:step|migration|intervention)", re.I), "manual step required"),
    (re.compile(r"(?:migration|upgrade)s?\s+required", re.I), "migration/upgrade required"),
]


def parse(tag):
    m = SEMVER.match((tag or "").strip())
    if not m:
        return None
    major, minor, patch, pre = m.groups()
    return (int(major), int(minor), int(patch), pre)


def key(v):
    """Sort key. A prerelease sorts below its own release (1.0.0-rc < 1.0.0)."""
    major, minor, patch, pre = v
    return (major, minor, patch, 0 if pre else 1, pre or "")


def crosses_boundary(a, b):
    """Is moving a -> b a breaking step by semver convention alone?

    Below 1.0.0 the minor is the compatibility boundary: semver says anything
    may change in 0.y.z, and in practice 0.4 -> 0.5 is where projects break
    things. At or above 1.0.0 it is the major.
    """
    if a[0] == 0 or b[0] == 0:
        if a[0] != b[0]:
            return "crosses 0.x -> %d.x" % b[0]
        if a[1] != b[1]:
            return "0.%d -> 0.%d (pre-1.0 minor is the compatibility boundary)" % (a[1], b[1])
        return None
    if a[0] != b[0]:
        return "major %d -> %d" % (a[0], b[0])
    return None


def fetch(repo, token):
    """Release list, newest first. Paginates until GitHub runs out."""
    out, page = [], 1
    while page <= 5:
        url = "https://api.github.com/repos/%s/releases?per_page=100&page=%d" % (repo, page)
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "hetzner-update-skill",
            **({"Authorization": "Bearer %s" % token} if token else {}),
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                batch = json.load(r)
        except urllib.error.HTTPError as e:
            hint = ""
            if e.code in (403, 429):
                hint = ("  Unauthenticated GitHub allows 60 requests/hour. "
                        "Run `gh auth login` or set GITHUB_TOKEN.")
            die("GitHub API %d for %s.%s" % (e.code, repo, hint))
        except urllib.error.URLError as e:
            die("cannot reach GitHub: %s" % e.reason)
        if not isinstance(batch, list):
            die("unexpected API reply for %s" % repo)
        out += batch
        if len(batch) < 100:
            break
        page += 1
    return out


def gh_token():
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        return tok
    try:
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def die(msg):
    print(json.dumps({"error": msg}, indent=2))
    sys.exit(2)


def self_test():
    """Offline check of the two things that fail silently: the version
    boundary rule, and the body scanner's false positives."""
    def boundary(a, b):
        return crosses_boundary(parse(a), parse(b))

    assert boundary("v0.4.18", "v0.4.19") is None, "patch bump must be safe"
    assert boundary("v0.4.19", "v0.5.0"), "pre-1.0 minor must be breaking"
    assert boundary("v0.9.0", "v1.0.0"), "0.x -> 1.0 must be breaking"
    assert boundary("v1.2.0", "v1.3.0") is None, "post-1.0 minor must be safe"
    assert boundary("v1.9.9", "v2.0.0"), "major bump must be breaking"

    def fires(body):
        return [w for p, w in BODY_SIGNALS if p.search(body)]

    assert fires("BREAKING CHANGE: config key renamed")
    assert fires("* a1b2c3d feat(api)!: remove the v1 endpoint")
    assert fires("feat!: drop node 18")
    assert fires("Action required: rotate your token before upgrading")
    assert fires("This release needs a manual migration of the cache dir")
    # Must stay quiet: a project that auto-applies schema migrations says
    # "migration" constantly, and flagging that makes the check useless.
    assert not fires("Running database migrations...\n  skip 001_init (already applied)")
    assert not fires("* 9f8e7d6 fix(db): speed up the migration runner")
    assert not fires("* 1234abc feat(chat): add a managed follow-up queue (#6211)")

    assert parse("0.4.19") == (0, 4, 19, None), "bare version must parse"
    assert parse("nightly-build") is None, "non-semver must not parse"
    assert key(parse("v1.0.0-rc.1")) < key(parse("v1.0.0")), "prerelease sorts first"

    print("self-test: all assertions passed")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name on GitHub")
    ap.add_argument("--current", required=True, help="installed version, e.g. v0.4.18")
    ap.add_argument("--allow-breaking", action="store_true",
                    help="target the newest release even across a breaking step")
    ap.add_argument("--prerelease", action="store_true", help="consider prereleases too")
    args = ap.parse_args()

    cur = parse(args.current)
    if not cur:
        die("cannot parse --current %r as semver" % args.current)

    rels = []
    for r in fetch(args.repo, gh_token()):
        if r.get("draft"):
            continue
        if r.get("prerelease") and not args.prerelease:
            continue
        v = parse(r.get("tag_name", ""))
        if v:
            rels.append({"v": v, "tag": r["tag_name"], "body": r.get("body") or "",
                         "published": r.get("published_at")})
    if not rels:
        die("no parseable releases for %s" % args.repo)
    rels.sort(key=lambda r: key(r["v"]))

    newer = [r for r in rels if key(r["v"]) > key(cur)]
    latest = rels[-1]

    # Walk upward. Each hop is classified against the version before it, so a
    # breaking release is caught even when it is not the newest one.
    steps, prev, first_breaking = [], cur, None
    for r in newer:
        reasons = []
        b = crosses_boundary(prev, r["v"])
        if b:
            reasons.append(b)
        for pat, why in BODY_SIGNALS:
            if pat.search(r["body"]):
                reasons.append(why)
        steps.append({"tag": r["tag"], "published": r["published"], "breaking": bool(reasons),
                      "reasons": reasons})
        if reasons and first_breaking is None:
            first_breaking = r["tag"]
        prev = r["v"]

    safe = [s["tag"] for s in steps if not s["breaking"]]
    # Everything up to (not including) the first breaking release.
    if first_breaking:
        idx = next(i for i, s in enumerate(steps) if s["tag"] == first_breaking)
        safe = [s["tag"] for s in steps[:idx]]

    if args.allow_breaking:
        target = latest["tag"] if newer else None
    else:
        target = safe[-1] if safe else None

    if not newer:
        status = "current"
    elif target is None:
        status = "blocked"          # next release is breaking; nothing safe to take
    elif target == latest["tag"]:
        status = "latest"
    else:
        status = "partial"          # can move, but not all the way

    print(json.dumps({
        "repo": args.repo,
        "current": args.current,
        "latest": latest["tag"],
        "target": target,
        "status": status,
        "releases_ahead": len(newer),
        "first_breaking": first_breaking,
        "steps": steps,
    }, indent=2))


if __name__ == "__main__":
    main()
