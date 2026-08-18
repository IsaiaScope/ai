#!/usr/bin/env python3
"""Replace a Dokploy compose stack's compose FILE with one from disk, then redeploy.

    dokploy-set-compose.py <composeId> <path> [--no-deploy]

The sibling of dokploy-set-env.py, and the other half of the same problem: that
script owns the Environment tab, this one owns the compose file itself. Which one
you need is decided by where the value has to end up.

  - A `${VAR}` the compose file already references  -> dokploy-set-env.py
  - A line the compose file does not have yet       -> this script

That distinction is not cosmetic, and getting it wrong fails silently. Dokploy
writes the Environment tab to a `.env` beside the compose file, and compose reads
`.env` for `${VAR}` INTERPOLATION ONLY — it does not pass those variables into
containers. Adding PYTHONPATH to the Environment tab of a stack whose compose
file never mentions PYTHONPATH changes nothing at all, and the panel shows the
key sitting there looking applied.

Runs ON the Dokploy host, talking to 127.0.0.1:3000 so it bypasses the Traefik
basicAuth in front of the panel. The API key is read from a curl-style config
file rather than taken as an argument, so `ps` on a shared host shows nothing:

    ~/.config/dokploy-api.conf      mode 600
    header = "x-api-key: <token>"

WHY IT IS SHAPED LIKE THIS
--------------------------
compose.update REPLACES the whole file — there is no patch endpoint — so a
truncated or half-written argument silently becomes the deployed stack, and the
next deploy is what tells you. Every step is therefore checked:

  1. refuse a file that is not a compose file (see looks_like_compose)
  2. GET the current composeFile and write it to a timestamped .bak, mode 600
  3. exit early if the stored file already matches — re-running is safe
  4. POST the new file
  5. RE-READ and compare byte for byte
  6. POST deploy

Step 5 is not paranoia. compose.update answers HTTP 200 for a composeId that does
not exist and does nothing at all — measured against Dokploy v0.29.13, 2026-08-06.
A 200 from that endpoint is not evidence of anything.

The helpers below are duplicated from dokploy-set-env.py rather than shared. That
is deliberate: these run on a host that has no checkout of this repo, copied there
one file at a time, and a common module is one more thing to remember to send.

USED FOR REAL, 2026-08-07: sofia's stack was missing PYTHONPATH and HF_HOME, so
the audio wheels in her state volume were unreachable and the TTS delivery patch
never loaded. The compose file was byte-identical to the repo's otherwise, which
is the case this script is safe in — it does not merge, it replaces.
"""

import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "http://127.0.0.1:3000/api"
CONF = Path.home() / ".config" / "dokploy-api.conf"


def die(msg):
    sys.exit("dokploy-set-compose: " + msg)


def token():
    """Read the API key out of the curl config file."""
    if not CONF.exists():
        die("no %s -- create it with mode 600 containing:\n"
            '  header = "x-api-key: <token>"' % CONF)
    m = re.search(r'^header\s*=\s*"x-api-key:\s*(.+?)"\s*$', CONF.read_text(), re.M)
    if not m:
        die("no 'header = \"x-api-key: ...\"' line in %s" % CONF)
    return m.group(1).strip()


def call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        API + "/" + path,
        data=data,
        headers={"x-api-key": token(), "Content-Type": "application/json"},
        method="POST" if data is not None else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = r.read().decode()
    except urllib.error.HTTPError as e:
        die("%s -> HTTP %s: %s" % (path, e.code, e.read().decode()[:300]))
    except urllib.error.URLError as e:
        die("%s -> %s" % (path, e))
    return json.loads(body) if body.strip() else {}


def looks_like_compose(text):
    """A cheap structural check, not validation.

    Deliberately regex and not yaml.safe_load: the Dokploy host has python3 but
    no guarantee of pyyaml, and a dependency that might be missing turns a guard
    into an exception at the worst moment. What this catches is the failure that
    actually happens -- an empty, truncated or wrong-path argument -- and that
    needs nothing cleverer than 'is there a top-level services: key'.
    """
    if not text.strip():
        return "file is empty"
    if not re.search(r"^services:\s*$", text, re.M):
        return "no top-level 'services:' key -- wrong file?"
    return None


def main():
    argv = sys.argv[1:]
    deploy = "--no-deploy" not in argv
    args = [a for a in argv if a != "--no-deploy"]
    if len(args) != 2:
        die("usage: dokploy-set-compose.py <composeId> <path> [--no-deploy]")
    compose_id, path = args

    src = Path(path)
    if not src.is_file():
        die("no such file: %s" % path)
    want = src.read_text()
    bad = looks_like_compose(want)
    if bad:
        die("refusing to post %s: %s" % (path, bad))

    cur = call("compose.one?composeId=" + compose_id)
    have = cur.get("composeFile")
    if have is None:
        die("compose.one returned no composeFile for %s -- wrong composeId?" % compose_id)
    name = cur.get("name", "stack")

    stamp = time.strftime("%Y%m%dT%H%M%S")
    backup = Path.home() / ("dokploy-compose-%s-%s.yml.bak" % (name, stamp))
    backup.write_text(have)
    backup.chmod(0o600)
    print("backup     : %s (%d bytes)" % (backup, len(have)))

    if have == want:
        # Not an error. This is what a re-run after a half-finished session looks
        # like, and the deploy below is still worth doing.
        print("unchanged  : stored composeFile already matches %s" % path)
    else:
        print("updating   : %d -> %d bytes" % (len(have), len(want)))
        call("compose.update", dict(composeId=compose_id, composeFile=want))
        again = call("compose.one?composeId=" + compose_id).get("composeFile")
        if again != want:
            die("the write did NOT take. compose.update reported success; it lies\n"
                "  for an unknown composeId. Stored file is unchanged, backup at\n"
                "  %s" % backup)
        print("verified   : stored composeFile now matches %s" % path)

    if not deploy:
        print("skipped    : deploy (--no-deploy)")
        return

    # Recreates the containers. Named volumes declared `external: true` are not
    # touched -- that is what keeps an agent's state across a redeploy.
    print("deploying  : compose.deploy")
    call("compose.deploy", dict(composeId=compose_id))
    print("deployed   : requested. Watch `docker ps` for the recreate; the API")
    print("             returns as soon as the job is queued, not when it lands.")


if __name__ == "__main__":
    main()
