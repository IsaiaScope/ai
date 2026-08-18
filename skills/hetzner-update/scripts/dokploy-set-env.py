#!/usr/bin/env python3
"""Set ONE key in a Dokploy compose stack's environment, then redeploy it.

    dokploy-set-env.py <composeId> <KEY> <value> [--no-deploy]

Runs ON the Dokploy host. Talks to 127.0.0.1:3000 directly, which bypasses the
Traefik basicAuth in front of the panel, so the only credential needed is the
Dokploy API key. That key is read from a curl-style config file rather than
taken as an argument:

    ~/.config/dokploy-api.conf      mode 600
    header = "x-api-key: <token>"

Nothing sensitive ever reaches argv, so `ps` on a shared host shows nothing.

WHY THIS EXISTS
---------------
Dokploy stores a compose stack's environment as a SINGLE STRING, not a map. The
update endpoint therefore replaces the whole block. Posting just the one key you
meant to change silently deletes every other key -- for multica that is
POSTGRES_PASSWORD, JWT_SECRET and RESEND_API_KEY, none of which are recoverable.

So this is a read-modify-write, and every step is checked:

  1. GET the current env, assert the target key is present
  2. rewrite ONLY that key's line
  3. assert the result has the same line count and the same key set
  4. POST the full block back
  5. RE-READ and confirm the value actually changed
  6. POST deploy

Step 5 is not paranoia. compose.update returns HTTP 200 for a composeId that
does not exist and does nothing at all -- measured against Dokploy v0.29.13,
2026-08-06. A 200 from that endpoint is not evidence of anything.

Secrets are never printed. Failures name the KEY, never the value.
"""

import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "http://127.0.0.1:3000/api"
CONF = Path.home() / ".config" / "dokploy-api.conf"


def die(msg):
    sys.exit("dokploy-set-env: " + msg)


def token():
    """Read the API key out of the curl config file."""
    if not CONF.exists():
        die("no %s -- create it with mode 600 containing:\n"
            '  header = "x-api-key: <token>"' % CONF)
    m = re.search(r'^header\s*=\s*"x-api-key:\s*(.+?)"\s*$',
                  CONF.read_text(), re.M)
    if not m:
        die("%s does not contain a parseable x-api-key header line" % CONF)
    return m.group(1)


def call(path, payload=None):
    """GET when payload is None, else POST JSON. Returns parsed body or None."""
    url = API + "/" + path
    data = None
    req_headers = {"x-api-key": token()}
    if payload is not None:
        data = json.dumps(payload).encode()
        req_headers["content-type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=req_headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read().decode().strip()
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:300]
        die("%s -> HTTP %s\n  %s" % (path, e.code, detail))
    except urllib.error.URLError as e:
        die("%s -> unreachable: %s\n  Is this running ON the Dokploy host?"
            % (path, e.reason))
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def keys_of(env):
    return [l.split("=", 1)[0] for l in env.splitlines() if l.strip()]


def main():
    args = [a for a in sys.argv[1:] if a != "--no-deploy"]
    deploy = "--no-deploy" not in sys.argv[1:]
    if len(args) != 3:
        die("usage: dokploy-set-env.py <composeId> <KEY> <value> [--no-deploy]")
    compose_id, key, value = args

    # ---- 1. read -----------------------------------------------------------
    cur = call("compose.one?composeId=" + compose_id)
    if not cur or "env" not in cur:
        die("composeId %s returned no compose record" % compose_id)

    env = cur.get("env") or ""
    before_keys = keys_of(env)
    if key not in before_keys:
        die("%s is not set on this stack. Present keys: %s"
            % (key, ", ".join(before_keys)))

    old_line = [l for l in env.splitlines() if l.startswith(key + "=")]
    if len(old_line) != 1:
        die("%s appears %d times; refusing to guess which one to change"
            % (key, len(old_line)))
    old_value = old_line[0].split("=", 1)[1]

    if old_value == value:
        print("%s is already %s -- rewriting anyway to exercise the path"
              % (key, value))

    # ---- 2. rewrite exactly one line ---------------------------------------
    new_env = "\n".join(
        (key + "=" + value) if l.startswith(key + "=") else l
        for l in env.splitlines()
    )

    # ---- 3. assert nothing else moved --------------------------------------
    after_keys = keys_of(new_env)
    if after_keys != before_keys:
        die("key set changed -- REFUSING to write.\n  before: %s\n  after:  %s"
            % (before_keys, after_keys))
    if len(new_env.splitlines()) != len(env.splitlines()):
        die("line count changed -- REFUSING to write")

    print("env: %d keys, changing %s only (%s -> %s)"
          % (len(after_keys), key, old_value, value))

    # ---- 4. write ----------------------------------------------------------
    call("compose.update", dict(composeId=compose_id, env=new_env))

    # ---- 5. verify, because 200 proves nothing -----------------------------
    # compose.update answers 200 for a composeId that does not exist and makes
    # no change. The only evidence the write landed is reading it back.
    again = call("compose.one?composeId=" + compose_id)
    check = [l for l in (again.get("env") or "").splitlines()
             if l.startswith(key + "=")]
    if not check or check[0].split("=", 1)[1] != value:
        die("write did NOT take effect -- %s is still %s.\n"
            "  compose.update returned success; it lies for an unknown "
            "composeId. Check that %s is correct."
            % (key, old_value, compose_id))
    if keys_of(again.get("env") or "") != before_keys:
        die("key set differs AFTER the write -- inspect the stack in the UI "
            "immediately")
    print("verified: %s=%s persisted, all %d keys intact"
          % (key, value, len(before_keys)))

    # ---- 6. deploy ---------------------------------------------------------
    if not deploy:
        print("--no-deploy: env updated, stack NOT redeployed")
        return
    print("deploying...")
    call("compose.deploy", dict(composeId=compose_id))
    print("deploy triggered. Poll the running image to confirm it landed:")
    print("  docker ps --no-trunc --filter name=<container> "
          "| tail -1 | tr -s ' ' | cut -d' ' -f2")


if __name__ == "__main__":
    main()
