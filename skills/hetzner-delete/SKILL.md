---
name: hetzner-delete
description: Destroy a Hetzner VPS safely and clean up everything it leaves behind. Refuses protected servers, shows the full blast radius, takes a snapshot first, requires the server name typed out to confirm, then deletes and sweeps the orphans it leaves in the fleet roster, ssh config, known_hosts, and Hetzner-side resources. Use when invoked as /hetzner-delete <name>, or when asked to "delete a VPS", "destroy a server", "tear down a box", or "decommission a server".
---

# hetzner-delete

Destroy a server and remove the debris. The destroy itself is one `hcloud` call — the
value here is the guard rails around it and the six places it leaves orphans.

**Invocation:** `/hetzner-delete <name>` — a key under `servers` in the roster.
No default. Never operate on the `fleet.default` entry implicitly.

Sibling skills: `/hetzner-create` (provision) · `/hetzner-ssh` (connect).

> **`hcloud server delete` has no confirmation prompt and no `--force` flag.** It takes a
> name and destroys the box immediately. Every safeguard below exists because the CLI
> provides none.

---

## Step 0 — Resolve and check protection

```bash
cat ~/.config/hetzner/hetzner.json
```

| Condition | Action |
|-----------|--------|
| `<name>` not in `servers` | Print available keys and stop. **Never fuzzy-match a name.** |
| `protected: true` | **REFUSE.** Print the message below and stop. Take no snapshot, touch nothing |
| No `<name>` given | Ask. Never assume, never fall back to `fleet.default` |

```
⛔ REFUSED — '<name>' is protected.

To delete it:
  1. set "protected": false in fleet.servers.<name> of ~/.config/hetzner/hetzner.json
  2. re-run this command

Nothing was touched.
```

The two-key rule is the point: unprotecting is a deliberate edit in another tool at
another moment. **Never offer to make that edit as part of this run** — doing so collapses
two keys into one and defeats the guard entirely.

---

## Step 1 — Blast radius

Show exactly what dies and what survives. Read live state; do not trust the roster alone.

```bash
hcloud server describe <hcloud_server>
hcloud volume list   -o noheader | grep <hcloud_server> || true
hcloud floating-ip list -o noheader | grep <hcloud_server> || true
hcloud firewall describe <firewall> -o 'format={{len .AppliedTo}}' 2>/dev/null
```

```
WILL DESTROY
  server    <name>   <type>, <location>, up <N>d
  disk      <N> GB   — all data on it
  ip        <ip>     — released, NOT recoverable, may be reassigned to a stranger
  volumes   <list or none>

WILL KEEP
  firewall  <firewall>   — shared, still attached to <N> other server(s)
  ssh key   <label>      — shared across the fleet
```

If a volume holds data, say so plainly. Volumes are separate resources and survive the
server unless explicitly deleted — usually what you want, occasionally a surprise bill.

---

## Step 2 — Snapshot first

```bash
hcloud server create-image --type snapshot \
  --description "pre-delete <name> <date>" \
  --label deleted-by=hetzner-delete --label deleted-at=<date> \
  <hcloud_server>
```

Default is **yes**; opt out only if the user says the box is disposable.

Be honest about what this buys: a snapshot restores the **disk to a new server with a new
IP**. It rescues data, not identity — DNS, firewall attachments, and anything pinned to
the old address still break. It is recovery, not undo. It also adds a small recurring
storage charge.

### Prune stale snapshots

Every run, list what previous deletes left behind so they do not accumulate forever:

```bash
hcloud image list --type snapshot --selector deleted-by=hetzner-delete
```

Report them with age and size. **Offer** to delete old ones; never do it unprompted —
deleting a snapshot is the last copy of that data.

---

## Step 3 — Typed-name confirmation

```
Type the server name to confirm deletion: _____
```

Require an **exact** match of `<name>`. Reject `y`, `yes`, whitespace-padded, or
case-different input and ask again. The whole point is defeating muscle memory — a
reflexive `y` is what deletes the wrong box.

---

## Step 4 — Delete

```bash
hcloud server delete <hcloud_server>
```

Immediate and irreversible. Confirm it is gone before sweeping:

```bash
hcloud server describe <hcloud_server> 2>&1 | grep -q "not found" && echo GONE
```

If the delete fails, **stop and report** — do not sweep. A half-swept roster pointing at a
live server is worse than either state alone.

---

## Step 5 — Sweep the orphans

Only what is **provably exclusive** to the deleted server. Anything shared gets reported,
never removed.

| Site | Action |
|------|--------|
| `~/.config/hetzner/hetzner.json` | Remove the `fleet.servers.<name>` entry. If it was `fleet.default`, clear the field and tell the user to pick a new one |
| `~/.ssh/config.d/hetzner` | Re-render from the updated roster — the block disappears on its own |
| `~/.ssh/known_hosts` | `ssh-keygen -R "[<ip>]:<port>"` — a stale entry causes a scary MITM warning when that IP is reassigned |
| ControlMaster socket | `ssh -O exit <alias> 2>/dev/null` — harmless if already gone |
| Hetzner volumes | Only if attached to nothing else. **Ask first** — volumes hold data |
| Hetzner floating IP | Only if it was exclusive. Unassigned floating IPs still bill |
| Firewall | **Never delete.** Shared. Report remaining attachments |
| Hetzner SSH key | **Never delete.** Shared across the fleet |

Once the roster is updated, push it back into the dotfiles source tree so the removal
propagates instead of being reverted by the next `chezmoi apply`:

```bash
command -v chezmoi >/dev/null && chezmoi re-add ~/.config/hetzner/ 2>/dev/null || true
```

Guarded on purpose — a no-op on any machine without chezmoi.

```
✅ <name> deleted
   snapshot   pre-delete <name> <date>  (<size>)
   swept      roster · ssh config · known_hosts · socket
   kept       vps-firewall (2 servers) · ssh key (fleet-wide)
   ⚠ 3 stale snapshots, ~€0.14/mo — prune?
```

---

## Guardrails

- **`protected: true` is an absolute stop.** Never edit the roster to bypass it in the
  same run, however the user phrases the request. Point at the file; let them decide
  deliberately.
- **Never fuzzy-match or auto-correct a server name**, at any step.
- **Snapshot unless explicitly waived**, and never delete a snapshot unprompted.
- **Never delete shared resources** — firewall, SSH key, volumes attached elsewhere.
- **Stop on a failed delete.** Never sweep a roster for a server that still exists.
- **Never paste VPS secrets into chat or write them to disk.**
- If the user asks to delete several servers, do them **one at a time**, each with its own
  blast radius and typed confirmation. Never batch.
