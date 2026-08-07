---
name: hetzner-ssh
description: Connect to a Hetzner VPS over SSH and end up in a position to actually work on it. Reads the fleet roster at ~/.config/hetzner/fleet.json, unlocks the ed25519 key from the macOS keychain, opens a multiplexed connection to a hardened host (key-only, non-standard port), verifies it is the right box, and hands back a live socket for subsequent commands. Use when invoked as /hetzner-ssh [server], or when asked to "get into the VPS", "ssh into the server", "connect to Hetzner", or to start working on a VPS.
---

# hetzner-ssh

Connect to a Hetzner VPS, prove it is the right one, and leave a **live multiplexed
connection** behind so every later command is cheap. Hosts are hardened: non-standard
sshd port, key-only auth, `AllowUsers` allowlist, Hetzner Cloud Firewall in front.

**Invocation:** `/hetzner-ssh [server]` — `server` is a key under `servers` in the roster.
Omit it to use the `default` entry.

Sibling skills: `/hetzner-create` (provision a new box) · `/hetzner-delete` (destroy one).
The roster schema is documented once, in `hetzner-create/README.md`.

---

## Step 0 — Load the roster

```bash
cat ~/.config/hetzner/fleet.json
```

(`$CLAUDE_SKILL_DIR` is **not** set in Claude Code — use the literal path above.)

| Condition | Action |
|-----------|--------|
| File missing | If you sync `~/.config/hetzner/` with a dotfiles manager, restore it there first (`chezmoi apply ~/.config/hetzner/`). Otherwise copy it from another machine, or run `/hetzner-create` to register a server. Stop. |
| Invalid JSON | Report the parse error and the offending line. Do not guess the contents. Stop. |
| Requested `server` not in `servers` | Print the available `servers` keys and stop. **Never guess a neighbouring name.** |
| No arg and no `default` key | Print the available keys and ask which one. Stop. |

Resolve the target: the user-supplied name, else `.default`. **Fields missing from a
server entry fall back to `defaults`** — so a lean entry is normal, not broken. Every
field below comes from the merged result; **do not re-discover any of it.**

| Field | Meaning |
|-------|---------|
| `ssh_alias` | `Host` alias in `~/.ssh/config.d/hetzner` — the actual connect target |
| `expect_hostname` | What `hostname` must print, or you are on the wrong box |
| `ip`, `port`, `user` | Rendered into the ssh_config block |
| `key`, `key_fingerprint_prefix` | Which key, and how to spot it in the agent |
| `protected` | Read by `/hetzner-delete`. Irrelevant here |
| `hcloud_*`, `location`, `firewall` | Only used on the failure paths below |
| `notes` | Free text: panel ports, runbook paths, quirks |

---

## Step 1 — Preflight (diagnose before you connect)

Three cheap checks, one shot. Each maps to a distinct remedy, so a failure says *which*
thing is broken instead of producing a generic `Permission denied`.

```bash
# 1. Does the ssh_config alias resolve? Prints the real HostName,
#    or echoes the alias back when no Host block matched.
ssh -G <ssh_alias> 2>/dev/null | awk '/^hostname /{print $2; exit}'

# 2. Is the private key present, and are its permissions sane?
ls -l <key> 2>/dev/null || echo "KEY-MISSING"

# 3. Is an agent reachable, and is our key already in it?
ssh-add -l 2>&1 | grep -q <key_fingerprint_prefix> && echo "KEY-LOADED" || echo "KEY-NOT-LOADED"
```

| Result | Meaning | Do this |
|--------|---------|---------|
| check 1 prints the `ip` from the roster | Alias resolves ✅ | Continue |
| check 1 echoes the alias back unchanged | No `Host` block | **Self-heal:** [re-render](#re-rendering-the-ssh-config) and retry check 1 once |
| check 1 prints a *different* IP | Roster and ssh_config disagree | Re-render (roster wins), then continue |
| check 2 prints `KEY-MISSING` | Private key not on this machine | If the key is vaulted in a dotfiles manager, restore it (`chezmoi apply ~/.ssh/`) and re-check. Otherwise **ask the user.** Never fabricate or regenerate a key — a new key is not in the box's `authorized_keys` |
| check 2 shows mode looser than `-rw-------` | ssh will refuse the key | `chmod 600 <key>` |
| check 3 prints `KEY-LOADED` | Skip to **Step 3** | |
| check 3 prints `KEY-NOT-LOADED` | Go to **Step 2** | |
| check 3 errors `Could not open a connection to your authentication agent` | No agent running | `eval "$(ssh-agent -s)"`, then Step 2 |

> `ssh-add -l` exits non-zero when the agent holds no identities. That is **normal**, not
> an error — do not treat the exit code as a failure. Only the `grep` result matters.

### Re-rendering the ssh config

`~/.ssh/config.d/hetzner` is a **pure render of the roster** — regenerate it freely, it
holds no hand-written state. One `Host` block per server in `servers`:

```sshconfig
# generated from ~/.config/hetzner/fleet.json — do not edit by hand
Host <ssh_alias>
  HostName <ip>
  Port <port>
  User <user>
  IdentityFile <key>
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
```

Never touch `~/.ssh/config` itself — it only needs `Include config.d/*` at line 1, which
is a one-time setup step (see `hetzner-create/README.md`). If that line is missing, the
rendered file is inert; say so rather than editing their config unasked.

---

## Step 2 — Load the key into the agent

The passphrase is in the macOS keychain, so no prompt is expected:

```bash
ssh-add --apple-use-keychain <key>
```

Three ways it goes wrong:

- **`--apple-use-keychain` unknown option** — non-macOS, or OpenSSH < 8.2. Retry with plain
  `ssh-add <key>`.
- **It prompts for a passphrase** — the keychain entry is gone. **Ask the user for the
  passphrase and let them type it.** Never hardcode it, never read it from a file, never
  type it on their behalf.
- **`Error connecting to agent`** — no agent. `eval "$(ssh-agent -s)"`, then retry.

---

## Step 3 — Connect + verify

One shot. `ControlMaster auto` means this call also **opens the multiplexed socket** — no
separate step needed.

```bash
ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new <ssh_alias> \
  'hostname; uptime | sed "s/^ *//"; \
   docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | head'
```

- `hostname` **must** equal `expect_hostname`. Anything else → **stop, run nothing else,
  report the mismatch.** A wrong box is the one failure where continuing makes it worse.
  Hetzner reuses IPs after a server is deleted, so a stale roster really can point at a
  stranger's machine.
- `docker ps` failing is **non-fatal** — report "docker unavailable" and continue.
- `accept-new` trusts a *first-seen* host key but still refuses a *changed* one.

**Do not retry a failed connect more than once.** Every failure below has a specific
remedy; a second identical `ssh` just burns time.

---

## Step 4 — Hand back a working position

The socket is now live and stays warm for 10 minutes past the last command. Report:
connected ✓, which server, uptime, containers — then **state the working handle**:

```bash
ssh <ssh_alias> '<command>'          # ~10ms, no re-auth, no handshake
ssh <ssh_alias> 'cd /opt/x && ...'   # each command is a fresh shell — chain for state
ssh <ssh_alias> 'sudo systemctl …'   # sudo is passwordless on boxes hetzner-create built
```

Then run whatever the user asked for, or ask what they want.

**Things to know while working:**

- **Each command is a fresh shell.** `cd`, `export`, and shell variables do not carry over.
  Chain with `&&` or use absolute paths.
- **Long jobs can be cut off.** `ControlPersist` keeps the *socket* warm, not the
  *process* — a dropped link SIGHUPs a running command. For anything multi-minute
  (`apt upgrade`, `docker build`), wrap it: `ssh <alias> 'nohup <cmd> > /tmp/job.log 2>&1 &'`
  then poll the log.
- **Close early if you want:** `ssh -O exit <ssh_alias>`. Otherwise it expires on its own.
- **`sudo`** is passwordless only on boxes provisioned by `/hetzner-create`. Older servers
  may prompt — if so, hand the prompt to the user.

---

## Error → diagnosis → fix

| Symptom | Actual cause | Fix |
|---------|--------------|-----|
| `Could not resolve hostname <alias>` | No `Host` block, or `Include` missing from `~/.ssh/config` | Re-render; if still failing, the `Include` line is absent — tell the user, do not edit their config |
| `Permission denied (publickey)` | Key not in agent, or not on the server | Preflight check 3. If loaded and still denied → the key is not in the box's `authorized_keys`; **ask the user** |
| Same, under `BatchMode`/cron | Encrypted key cannot be signed non-interactively. **Not** an auth failure | Load into the agent (Step 2), retry without `BatchMode` |
| `UNPROTECTED PRIVATE KEY FILE` | Key mode looser than 600 | `chmod 600 <key>` |
| Connection **times out** | Firewall, or the box is down | `hcloud server describe <hcloud_server> -o 'format={{.Status}}'`; `hcloud firewall describe <firewall> \| grep -iE 'port\|direction'`. Do not thrash SSH |
| Connection **refused** | Box up, sshd down or on another port | Confirm `port`; check the Hetzner console |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Rebuild, IP reuse — or MITM | Verify the fingerprint via the hcloud console **before** accepting. Do not blindly `ssh-keygen -R` |
| `hostname` ≠ `expect_hostname` | Wrong box — stale IP or reused alias | **Stop.** Compare `ip` against `hcloud server describe <hcloud_server>`; offer to update the roster and re-render |
| `ControlPath too long` | Socket path exceeds the ~104-char unix limit | Ensure the render uses `~/.ssh/cm-%C` (hashed), not `%r@%h:%p` |
| `ssh-add -l` exits 1 | Agent holds no identities | Normal. Proceed to Step 2 |
| `Could not open a connection to your authentication agent` | No agent in this shell | `eval "$(ssh-agent -s)"` |
| `fleet.json` not found | Roster not present on this machine | `chezmoi apply ~/.config/hetzner/` if you vault it; else copy from another machine, or `/hetzner-create` to register one |

---

## Guardrails

- **Never paste VPS secrets into chat or write them to disk.** Tokens, DB/MinIO/Dokploy
  passwords, and the age secret key live in the runbook and the server's own env — read
  them there, in place. `fleet.json` holds connection metadata only; no secrets.
- **Never type the user's passphrase, key material, or API token.** Hand any prompt to them.
- **Read-only by default.** Do not restart services, run migrations, or touch Dokploy
  unless the user asks for that specific action.
- **Never edit `~/.ssh/config`.** This skill owns `~/.ssh/config.d/hetzner` and nothing else.
- Prohibited on the user's behalf: money/trades, permission changes, hard deletes. Surface
  them; let the user do it. Destroying a server is `/hetzner-delete`, never an ad-hoc
  `hcloud server delete` from here.
