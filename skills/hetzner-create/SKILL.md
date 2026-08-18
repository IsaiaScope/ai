---
name: hetzner-create
description: Provision a new hardened Hetzner VPS end to end. Sets up the local toolchain if missing (hcloud CLI, API context, SSH keypair, ssh_config Include), then creates the server with the firewall attached and cloud-init hardening applied at first boot, verifies SSH comes up on the non-standard port, and registers it in the fleet roster. Use when invoked as /hetzner-create <name>, or when asked to "create a VPS", "provision a Hetzner server", "spin up a new box", or "set up a new server".
---

# hetzner-create

Create a Hetzner VPS that is hardened **before it ever answers on port 22**, then register
it so `/hetzner-ssh <name>` just works.

**Invocation:** `/hetzner-create <name> [--type X] [--location Y] [--image Z]`
`<name>` becomes the Hetzner server name, the hostname, and the roster key.
Unspecified options come from `defaults` in the roster.

Sibling skills: `/hetzner-ssh` (connect) · `/hetzner-delete` (destroy).

> **Creating a server starts a recurring charge.** Step 3 always confirms with the user
> before anything is created. Never skip it, never infer approval from the invocation.

---

## Step 0 — Load the roster

```bash
cat ~/.config/hetzner/hetzner.json
```

Missing file → this is the first server on this machine. Create it with a `defaults`
block (see [README](README.md)) rather than failing.

| Condition | Action |
|-----------|--------|
| `<name>` already in `servers` | **Refuse.** Never auto-suffix — a near-miss name is how the wrong box gets touched later. Ask for a different name |
| Invalid JSON | Report the parse error and line. Do not rewrite the file. Stop |
| No `<name>` given | Ask. Do not invent one |

Merge `defaults` with any command-line overrides to get the effective settings. Show them
back in Step 3 before spending money.

---

## Step 1 — Local preflight

Everything the create call depends on. Fix what is missing, in this order.

```bash
command -v hcloud            || echo "NO-HCLOUD"
hcloud context list          2>/dev/null | grep -q . || echo "NO-CONTEXT"
ls -l <key> <key>.pub        2>/dev/null || echo "NO-KEY"
grep -q "^Include" ~/.ssh/config 2>/dev/null || echo "NO-INCLUDE"
hcloud ssh-key list -o noheader 2>/dev/null | grep -q <key_fingerprint_prefix> || echo "NO-REMOTE-KEY"
```

| Missing | Fix | Who acts |
|---------|-----|----------|
| `hcloud` | `brew install hcloud` | agent |
| context | `hcloud context create <hcloud_context>` — **prompts for an API token** | **user pastes the token.** Never type it for them |
| private key | Copy from a password manager / another machine, then `chmod 600` | **user.** Never generate a replacement — the fleet shares one key |
| `<key>.pub` | `ssh-keygen -y -f <key> > <key>.pub` (needs the agent) | agent |
| `Include` line | Add `Include config.d/*` as **line 1** of `~/.ssh/config`, above any `Host *`, after backing it up | **confirm with user first** |
| Hetzner-side key | `hcloud ssh-key create --name <label> --public-key-from-file <key>.pub` | agent |

`Include` must be line 1: ssh takes the **first** value it sees for each keyword, so a
`Host *` block above the Include would silently override the generated entries.

---

## Step 2 — Ensure the firewall exists

Attached at creation, so it must exist first. Shared across the fleet by name — create it
once, never modify it if it is already there (other servers depend on it).

```bash
hcloud firewall describe <firewall> >/dev/null 2>&1 || \
  hcloud firewall create --name <firewall>
# inbound: <port>, 80, 443 — nothing else
```

If it already exists, **verify** `<port>` is allowed inbound and say so. A firewall
missing the SSH port produces a server that boots perfectly and is unreachable forever.

---

## Step 3 — Confirm the charge

Show the user exactly what will be created and what it costs, then wait for a clear yes:

```
CREATE  <name>
  type      cax11   (2 vCPU ARM, 4 GB)   ~€3.29/mo
  image     ubuntu-24.04
  location  fsn1
  firewall  vps-firewall   (inbound 2222/80/443)
  user      isoonfire      (sudo NOPASSWD, key-only)
  sshd      port 2222, no root, no passwords

Recurring charge. Proceed? [y/N]
```

No explicit yes → stop. Nothing has been created at this point.

---

## Step 4 — Render cloud-init and create

Render `cloud-init.yaml` to a temp file, substituting `{{USER}}`, `{{SSH_PUBKEY}}`
(contents of `<key>.pub`), `{{SSH_PORT}}`, `{{HOSTNAME}}`.

```bash
hcloud server create \
  --name <name> \
  --type <type> \
  --image <image> \
  --location <location> \
  --ssh-key <label> \
  --firewall <firewall> \
  --user-data-from-file /tmp/cloud-init-<name>.yaml
```

> **The `ssh_authorized_keys` line in the rendered file is load-bearing.** `--ssh-key`
> injects the public key into **root** only, and the baseline sets `PermitRootLogin no` +
> `AllowUsers <user>`. Without the key also on `<user>`, the server is unreachable — every
> time, not occasionally. Verify the substitution happened before creating.

---

## Step 5 — Wait for the box, then verify

cloud-init takes 1–3 minutes (package install dominates). Render the roster entry and the
ssh_config block first so the alias exists to poll against.

```bash
# poll, ~180s budget
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new <alias> \
    'test -f /var/lib/cloud/hetzner-create-done && hostname'
```

- Prints `<name>` → cloud-init finished. Run the health check below.
- Connection refused for the first ~60s → **expected**, cloud-init has not restarted sshd
  yet. Keep polling.
- `hostname` mismatch → stop and report. Something is very wrong.

### Health check — the marker is not the acceptance test

`runcmd` does not `set -e`, so a failed step is logged and the script carries on to
`touch` the marker anyway. The marker means *cloud-init ran to the end*, not *the baseline
applied*. Verify the parts that can fail silently:

```bash
ssh <alias> '
  systemctl is-active --quiet crowdsec  && echo "crowdsec   ok" || echo "crowdsec   FAILED"
  [ "$(systemctl is-enabled ssh.socket 2>/dev/null)" = masked ] \
                                        && echo "ssh.socket masked" || echo "ssh.socket NOT-MASKED"
  ss -tln | grep -q ":<port> "          && echo "port       ok" || echo "port       FAILED"
'
```

> Compare the **string**, not the exit code. `systemctl is-enabled --quiet ssh.socket`
> exits non-zero for `disabled` *and* `masked`, so an exit-code test reports success on a
> box that is merely disabled — the exact state the mask exists to make permanent.

| Result | Meaning | Action |
|--------|---------|--------|
| all ok | Baseline applied | Continue to Step 6 |
| `crowdsec FAILED` | Repo script or apt failed — box is up, but has **no IDS at all** | Register it, report **unhardened**. Fix by re-running the CrowdSec lines over SSH |
| `ssh.socket NOT-MASKED` | The mask did not take | sshd can move to `:22` on the next boot. Mask it now |
| `port FAILED` | sshd is not on `<port>` — you reached the box some other way | Stop. Do not register |

**Never report "hardened" on a failed check.** A box described as hardened that is not is
worse than one known to be half-built — nobody goes back to fix what was reported green.

### If it never comes up

Keep the server — it is the only way to see what failed. Report, and hand over:

```bash
# read the cloud-init output
hcloud server request-console <name>

# fix cloud-init.yaml, then re-apply IN PLACE (same IP, roster stays valid)
hcloud server rebuild <name> --image <image> \
  --user-data-from-file /tmp/cloud-init-<name>.yaml

# or give up — user runs this, never the agent
hcloud server delete <name>
```

`rebuild` reimages the disk while keeping the server and its IP, so the roster entry and
rendered ssh_config stay correct. Prefer it over delete-and-recreate.

---

## Step 6 — Register

Write the entry into `fleet.servers` in `~/.config/hetzner/hetzner.json`. Only record what
differs from `fleet.defaults` plus the facts that are genuinely per-server:

```jsonc
"<name>": {
  "ssh_alias": "<name>-vps",
  "expect_hostname": "<name>",
  "ip": "<from hcloud server ip>",
  "hcloud_server": "<name>",
  "hcloud_id": "<from create output>",
  "protected": false,
  "notes": "created <date> by hetzner-create"
}
```

Then re-render `~/.ssh/config.d/hetzner` from the whole roster (one `Host` block per
server — the format is in `hetzner-ssh/SKILL.md`).

Then push the updated roster back into the dotfiles source tree, so the new server
survives a rebuild and reaches your other machines:

```bash
command -v chezmoi >/dev/null && chezmoi re-add ~/.config/hetzner/ 2>/dev/null || true
```

Guarded on purpose — a no-op on any machine without chezmoi. The roster stays
authoritative in `~/.config/hetzner/` either way; this only stops a one-way
`chezmoi apply` from later reverting the registration.

Finally, report:

```
✅ <name> ready — <ip>, hardened, registered
   /hetzner-ssh <name>
```

Set `protected: true` once the box carries anything you would miss.

---

## What this does NOT install

The baseline is deliberately server-level only, identical on every box: user + sudo, sshd,
firewall, unattended-upgrades, sysctl, CrowdSec.

Application stacks — Dokploy, n8n, Hermes, databases — are **out of scope**. They differ
per box, carry their own CVEs and config, and would turn this into a deployment framework.
Install them afterwards from the relevant runbook.

---

## Guardrails

- **Confirm before creating.** Recurring charge, always explicit.
- **Never run `hcloud server delete`.** Print it; the user runs it. Destroying a
  registered server is `/hetzner-delete`.
- **Never type the user's API token, passphrase, or key material.** Hand prompts over.
- **Never generate a replacement SSH key.** A new key is not in any existing box's
  `authorized_keys`, and the fleet shares one.
- **Never modify an existing shared firewall** — other servers are attached to it. Verify
  and report instead.
- **Only ever write `~/.ssh/config.d/hetzner`.** `~/.ssh/config` gets exactly one confirmed
  one-time edit (the `Include` line), with a backup.
