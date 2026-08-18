# Software registry — the `software` section of `~/.config/hetzner/hetzner.json`

Every command `/hetzner-update` runs comes from here. Adding an app is a JSON entry, not
a code change.

This section shares `~/.config/hetzner/hetzner.json` with the `fleet` section, which is
documented in `hetzner-create/README.md`. The file **is** tracked by chezmoi. It holds
paths and hostnames, no credentials — everything that needs auth goes through `ssh` or `gh`.

---

## Schema

```
software.<key>
├── server              required · key in fleet.servers. Which box this runs on
├── repo                required · owner/name on GitHub, for the release list
├── pinned              required · version currently running. The skill updates this
├── release_notes_url   optional · offered to the user before a breaking jump
├── notes               optional · free text, quirks worth reading at 3am
│
├── local               the client half on your Mac
│   ├── version_cmd     required · must print a bare semver and nothing else
│   ├── self_updating   optional · true = cannot be pinned or forced, only reported
│   └── upgrade_cmd     optional · omit when self_updating
│
├── remote              the service half on the VPS
│   ├── version_cmd     required · must print a bare semver and nothing else
│   ├── upgrade_cmd     required · {version} is substituted with the approved target
│   └── verify_cmd      optional · asks the running service its own version
│
├── backup_cmd          required when the app has state. Must produce a restore point
├── backup_verify_cmd   optional · proves the dump is usable, not merely present
│
└── companions[]        other binaries sharing the name. May lag harmlessly
    ├── name
    ├── version_cmd
    └── upgrade_cmd
```

**`version_cmd` must print only the version.** The planner parses its stdout as semver, so
do the extraction in the command. `multica --version` prints
`multica 0.4.19 (commit: a8d5daac5, ...)` — pipe it through `awk` rather than teaching the
planner every app's output format.

**Two placeholders, both substituted before a command runs:**

| | |
|---|---|
| `{version}` | the tag the user approved in Step 3, verbatim, including any `v` prefix |
| `{alias}` | `ssh_alias` for this entry's `server`, read from `fleet.servers` |

Write `ssh {alias}`, never a literal alias. The roster owns the connection details, and a
hardcoded alias keeps working right up until the box is renamed — at which point the
`server` field is decorative and the command reaches for a host that no longer answers.

---

## Worked example — Multica

Multica is the case this skill was written against, and it exercises every field. It is a
project board whose daemon runs on the Mac and whose server runs on VPS-1; the two speak a
protocol with no stability guarantee before 1.0, which is why they are pinned together.

```json
{
  "software": {
    "multica": {
      "server": "main",
      "repo": "multica-ai/multica",
      "pinned": "v0.4.19",
      "release_notes_url": "https://github.com/multica-ai/multica/releases",
      "notes": "Three binaries answer to 'multica'. The daemon is the one inside the app bundle; the Homebrew CLI is a separate tool that is no part of the pin. Never verify with a bare `multica --version` — $PATH resolves it to the CLI.",

      "local": {
        "version_cmd": "'/Applications/Multica.app/Contents/Resources/app.asar.unpacked/resources/bin/multica' --version | awk 'NR==1{print $2}'",
        "self_updating": true
      },

      "remote": {
        "version_cmd": "ssh {alias} 'grep \"^MULTICA_IMAGE_TAG=\" /opt/multica/.env | cut -d= -f2'",
        "upgrade_cmd": "ssh {alias} 'set -e; cd /opt/multica; sed -i \"s|^MULTICA_IMAGE_TAG=.*|MULTICA_IMAGE_TAG={version}|\" .env; docker compose pull; docker compose up -d'",
        "verify_cmd": "curl -s https://multica.isaiariva.com/api/config | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"server_version\"])'"
      },

      "backup_cmd": "ssh {alias} 'TS=$(date +%Y%m%d-%H%M%S); docker exec multica-postgres pg_dump -U multica -d multica --clean --if-exists | gzip > /opt/multica/pre-upgrade-$TS.sql.gz; echo /opt/multica/pre-upgrade-$TS.sql.gz'",
      "backup_verify_cmd": "ssh {alias} 'F=$(ls -t /opt/multica/pre-upgrade-*.sql.gz | head -1); gzip -t \"$F\" && zcat \"$F\" | grep -c \"^CREATE TABLE\"'",

      "companions": [
        {
          "name": "homebrew CLI",
          "version_cmd": "/opt/homebrew/bin/multica --version | awk 'NR==1{print $2}'",
          "upgrade_cmd": "brew update && brew upgrade multica"
        }
      ]
    }
  }
}
```

### Why each awkward bit is there

- **`local.self_updating: true`** — the daemon ships inside an Electron app that updates
  itself. There is no way to hold it at a version, so when the local half is ahead the only
  move is bringing the server up. When it is *behind*, the skill must stop and ask the user
  to update the app, never downgrade the server to meet it.
- **`brew update` inside the companion's upgrade** — a bare `brew upgrade multica` reports
  `already installed` while the tap's index is stale, which looks exactly like a no-op that
  was not needed.
- **`backup_verify_cmd` counts tables** — `pg_dump` can exit 0 having written a truncated
  file. Counting `CREATE TABLE` proves the dump has structure; a bare size check does not.
- **`verify_cmd` asks the service** — the running server reports its own version over HTTP.
  Anything read locally can be a different binary that happens to agree.

---

## Adding an app

1. Confirm it tags releases as semver on GitHub. If it does not, this skill cannot plan an
   upgrade for it — say so rather than half-supporting it.
2. Write the entry. Set `pinned` to what is running *now*, not what you want.
3. Test each `version_cmd` by hand first. They must print a bare version:

   ```bash
   # right
   0.4.19
   # wrong — the planner cannot parse this
   multica 0.4.19 (commit: a8d5daac5, built: 2026-08-05T10:24:43Z)
   ```
4. Run `/hetzner-update <key> --check`. It reads and reports without changing anything.
