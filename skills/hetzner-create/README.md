# Hetzner fleet skills — setup guide

Three skills covering the whole life of a Hetzner VPS. This README is the shared
reference: roster schema, machine setup, troubleshooting.

| Skill | Runs | Does |
|-------|------|------|
| `/hetzner-create <name>` | per server | Local preflight → confirm charge → create hardened box → verify → register |
| `/hetzner-ssh [name]` | daily | Preflight → connect over a multiplexed socket → verify box → hand back a working position |
| `/hetzner-delete <name>` | rare | Protection check → blast radius → snapshot → typed confirm → delete → sweep orphans |

---

## How it fits together

```
/hetzner-create  ──→  /hetzner-ssh  ──→  /hetzner-delete
   born hardened      daily driver       snapshot + sweep
        │                   │                   │
        └───── writes ─→ fleet.json ←─ prunes ──┘
                             │
                    renders (one-way, total)
                             ↓
                  ~/.ssh/config.d/hetzner
                             ↑
              ~/.ssh/config: Include config.d/*   (line 1)
```

**`~/.config/hetzner/fleet.json` is the single source of truth.**
`~/.ssh/config.d/hetzner` is a pure render of it — regenerate it any time, it holds no
hand-written state. Because the render is one-way and total, the two cannot drift.

Deliberate split:

| Part | Contains | Travels? |
|------|----------|----------|
| Skill dirs | logic only, zero fleet data | ✅ with the repo |
| `~/.config/hetzner/fleet.json` | ip, port, user, aliases, hcloud ids | ⚠️ machine-local by default; no secrets, so it is safe to track in a **private** dotfiles repo |
| `~/.ssh/id_ed25519_hetzner` + passphrase | the actual credential | ❌ never in this repo — it is public. Encrypted in a private vault (age, sops) is a separate decision |
| `~/.ssh/config.d/hetzner` | generated | ❌ regenerated on demand |

So cloning the repo gets you the tooling, never the access.

---

## Prerequisites

| Requirement | Check | Notes |
|-------------|-------|-------|
| OpenSSH ≥ 8.2 | `ssh -V` | `--apple-use-keychain` needs 8.2+; older → plain `ssh-add` |
| macOS | — | Keychain passphrase persistence is macOS-only; Linux needs a keyring agent |
| `hcloud` CLI | `hcloud version` | Required by create/delete. `/hetzner-ssh` only needs it on failure paths |
| Hetzner API token | `hcloud context list` | Project-scoped, read/write |
| The private key | `ls -l ~/.ssh/id_ed25519_hetzner` | From a password manager or another machine |

---

## Install

```bash
for s in hetzner-ssh hetzner-create hetzner-delete; do
  ln -s /Volumes/Crucial-4T/repo/ai/skills/$s ~/.claude/skills/$s
done
```

Each symlink name must equal the `name:` in that skill's frontmatter, or the slash command
will not resolve. The repo lives on an external drive — unmount it and the skills vanish.
That is the intended failure mode; they report it rather than half-working.

---

## New machine setup

Four things, in order. Only `hcloud` is optional, and only for `/hetzner-ssh`.

### 1. Private key

Copy it from a password manager or an existing machine. **Do not generate a new one** —
the fleet shares one key, and a fresh key is in nobody's `authorized_keys`.

```bash
chmod 600 ~/.ssh/id_ed25519_hetzner
ssh-keygen -lf ~/.ssh/id_ed25519_hetzner    # must start with key_fingerprint_prefix
ssh-keygen -y -f ~/.ssh/id_ed25519_hetzner > ~/.ssh/id_ed25519_hetzner.pub   # if missing
```

`chmod 600` is not cosmetic — ssh refuses any key readable by others
(`UNPROTECTED PRIVATE KEY FILE`). The `.pub` is needed by `/hetzner-create` to embed in
cloud-init.

### 2. The `Include` line — **must be line 1**

```bash
cp ~/.ssh/config ~/.ssh/config.bak
printf 'Include config.d/*\n\n%s' "$(cat ~/.ssh/config)" > ~/.ssh/config.new \
  && mv ~/.ssh/config.new ~/.ssh/config
mkdir -p ~/.ssh/config.d && chmod 700 ~/.ssh/config.d
```

SSH takes the **first** value it sees for each keyword, not the last. A `Host *` block
above the Include would silently override `HostName`/`Port`/`User`/`IdentityFile` in every
generated entry. Line 1 makes that impossible.

### 3. The roster

```bash
mkdir -p ~/.config/hetzner
cp fleet.example.json ~/.config/hetzner/fleet.json   # then edit
```

It holds connection metadata only, no secrets, so it is safe to track in a private dotfiles
repo — `/hetzner-create` and `/hetzner-delete` run `chezmoi re-add ~/.config/hetzner/` after
they mutate it, so a synced roster stays current on its own. Without that, it is machine-local:
on a fresh machine you either copy it across or re-register servers with `/hetzner-create`.

### 4. `hcloud`

```bash
brew install hcloud
hcloud context create vps      # paste the API token — the agent never types it
hcloud server list
```

### Verify

```bash
ssh -G main-vps | awk '/^hostname /{print $2}'   # → the IP, not "main-vps"
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_hetzner
ssh-add -l | grep cCsgfwGqw6
ssh -o ConnectTimeout=8 main-vps hostname        # → main
```

Four passes = everything works.

---

## `fleet.json` schema

```jsonc
{
  "default": "main",              // used when /hetzner-ssh gets no argument
  "defaults": { /* inherited by every server; overridden per entry */ },
  "servers": { "main": { /* ... */ } }
}
```

### `defaults`

Applied to new servers and used as fallback for any field an entry omits.

| Field | Example | Purpose |
|-------|---------|---------|
| `type` | `cax11` | Hetzner server type for new boxes |
| `image` | `ubuntu-24.04` | Base image. LTS to 2029; matches the rest of the fleet |
| `location` | `fsn1` | Datacenter |
| `port` | `2222` | sshd port set by cloud-init |
| `user` | `isoonfire` | Non-root sudo user created at first boot |
| `key` | `~/.ssh/id_ed25519_hetzner` | Fleet-wide private key |
| `key_fingerprint_prefix` | `cCsgfwGqw6` | How to spot that key in `ssh-add -l` |
| `firewall` | `vps-firewall` | Shared firewall, attached at creation |
| `hcloud_context` | `vps` | Which hcloud context to operate in |
| `protected` | `false` | New servers start deletable |

### A server entry

| Field | Required | Purpose |
|-------|:--------:|---------|
| `ssh_alias` | ✅ | `Host` alias — the actual connect target |
| `expect_hostname` | ✅ | What `hostname` must print. Wrong-box guard |
| `ip` | ✅ | `HostName` in the rendered block |
| `protected` | ✅ | `true` → `/hetzner-delete` refuses outright |
| `port`, `user`, `key`, `key_fingerprint_prefix` | ➖ | Inherited from `defaults` unless overridden |
| `hcloud_server`, `hcloud_id`, `hcloud_context`, `location`, `firewall` | ➖ | Infra ops and failure diagnosis |
| `notes` | ➖ | Panel ports, runbook paths, quirks |

**No secrets in this file.** Tokens, DB passwords, and the age key live on the server or
in the password manager.

### Pre-existing servers

Boxes not built by `/hetzner-create` migrate as-is — override whatever differs. `main`
runs as `main-user`, not the `isoonfire` default, and simply carries `"user": "main-user"`.
Renaming a user on a live box means moving `$HOME`, re-chowning its files, and editing
`AllowUsers`; nothing here requires it.

---

## What `/hetzner-create` installs

Server-level only, identical on every box:

| | |
|---|---|
| user | `isoonfire`, sudo NOPASSWD, key-only, password locked |
| sshd | port 2222, no root, no passwords, `AllowUsers`, `MaxAuthTries 3` |
| firewall | inbound 2222 / 80 / 443, attached at creation |
| updates | `unattended-upgrades` |
| kernel | sysctl hardening (rp_filter, no redirects, syncookies, …) |
| IDS | CrowdSec + `crowdsec-firewall-bouncer-nftables`. No fail2ban — one banner, one backend |

**Not installed:** Dokploy, n8n, Hermes, databases, tmux. Application stacks differ per
box and carry their own CVEs and config — install them afterwards from the relevant
runbook.

### Why cloud-init and not post-provision SSH

The server is created with `--firewall` and `--user-data-from-file` in the same call, so
it boots already hardened. There is never a window where a default-config `:22` faces the
internet — Hetzner ranges get scanned within minutes.

Two details keep it from bricking:

- **`ssh_authorized_keys` on the user is mandatory.** `--ssh-key` injects the public key
  into **root** only, and the baseline sets `PermitRootLogin no` + `AllowUsers <user>`.
  Omit it and the box is unreachable — deterministically, not occasionally.
- **Ordering is free with cloud-init.** The `users` module runs in the *init* stage,
  `runcmd` in the *final* stage, so the user exists with its key before sshd restarts
  hardened. Doing the same work purely in `runcmd` risks locking yourself out.
- **`ssh.socket` is masked before sshd restarts.** Ubuntu 22.10+ can socket-activate
  sshd, and when it does, systemd owns the listener and `Port` in `sshd_config` is
  ignored — sshd answers on 22 while the firewall only opens 2222. Hetzner's image ships
  it disabled, so masking converts a default into an invariant.

If cloud-init fails, use `hcloud server rebuild --user-data-from-file` — it reimages **in
place, same IP**, so the roster and rendered config stay valid. Prefer it over
delete-and-recreate.

---

## Working on a box

`/hetzner-ssh` leaves a multiplexed socket open (`ControlMaster auto`, `ControlPersist
10m`). Subsequent commands reuse it — no handshake, no re-auth, ~10 ms each.

```bash
ssh main-vps 'docker ps'
ssh main-vps 'cd /opt/backups && ./backup.sh'    # fresh shell each time — chain for state
ssh main-vps 'sudo systemctl restart caddy'      # passwordless on hetzner-create boxes
ssh -O exit main-vps                             # close early; otherwise it expires
```

- **Each command is a fresh shell** — `cd`, `export`, and variables do not carry over.
- **Long jobs can be cut off.** `ControlPersist` keeps the socket warm, not the process; a
  dropped link SIGHUPs a running command. For multi-minute work:
  `ssh main-vps 'nohup <cmd> > /tmp/job.log 2>&1 &'`, then poll the log.
- `ControlPath` uses `~/.ssh/cm-%C` (hashed) because macOS caps unix socket paths near 104
  characters.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Slash command not recognised | Symlink missing/dangling, or name ≠ frontmatter `name:` | Re-run [Install](#install); restart Claude Code |
| `fleet.json` not found | Not present on this machine | `chezmoi apply ~/.config/hetzner/` if you vault it; else copy it across, or `/hetzner-create` |
| `Could not resolve hostname <alias>` | No `Host` block, or `Include` missing/not line 1 | Re-render; check line 1 of `~/.ssh/config` |
| Generated block seems ignored | `Host *` sits above the `Include` | Move `Include config.d/*` to line 1 |
| `Permission denied (publickey)` | Key not in agent, or not on the server | `ssh-add -l`; if loaded, the box lacks the public half |
| Same, under `BatchMode`/cron | Encrypted key can't be signed non-interactively | Load into the agent, drop `BatchMode`. Not an auth failure |
| `UNPROTECTED PRIVATE KEY FILE` | Key mode looser than 600 | `chmod 600 <key>` |
| `ControlPath too long` | Socket path over the unix limit | Use `~/.ssh/cm-%C`, not `%r@%h:%p` |
| New server times out forever | Firewall missing the SSH port, or cloud-init failed | `hcloud firewall describe`; `hcloud server request-console <name>` |
| New server refuses connections for ~60s | cloud-init hasn't restarted sshd yet | Expected. Keep polling |
| Unreachable on `<port>`, sshd alive on 22 | `ssh.socket` enabled — systemd owns the port, `sshd_config` ignored | Via console: `systemctl mask ssh.socket && systemctl restart ssh`. cloud-init masks it on new boxes |
| Connection times out (existing box) | Firewall or dead box | `hcloud server describe <name> -o 'format={{.Status}}'` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Rebuild / IP reuse — or MITM | Verify via hcloud console **before** accepting. Don't blindly `ssh-keygen -R` |
| `hostname` ≠ `expect_hostname` | Wrong box — stale IP, reused alias | Stop. Hetzner reassigns IPs after deletion |
| `ssh-add -l` exits 1 | Agent holds no identities | Normal. Load the key |
| `ssh-add: unknown option --apple-use-keychain` | Non-macOS or OpenSSH < 8.2 | Plain `ssh-add` |

---

## Security model

- **`fleet.json` carries no secrets** — connection metadata only.
- **The agent never types credentials.** Passphrases, API tokens, key material: the user
  types them. Never hardcoded, never read from a file.
- **Creating a server always confirms** — it starts a recurring charge.
- **Deleting requires two keys**: `protected: false` in the roster *and* the server name
  typed out. `hcloud server delete` has no prompt of its own, which is exactly why.
- **Wrong-box guard is a hard stop.** `hostname` ≠ `expect_hostname` aborts before any
  command runs — Hetzner reassigns released IPs, so a stale roster can point at a
  stranger's server.
- **Passwordless sudo is deliberate.** With key-only auth, no root login, and an
  `AllowUsers` allowlist, the SSH key is already the whole credential; a stored sudo
  password would add friction, not security. Compromise of the key means root — mitigated
  by the firewall, CrowdSec, and `MaxAuthTries`.
- **Shared resources are never swept.** The firewall and the fleet SSH key survive any
  delete.
