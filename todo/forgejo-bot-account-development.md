# Forgejo bot account for `development` — DONE (2026-08-02)

`developmentbot` gives the `development` host (192.168.2.184) its own Forgejo
identity, so Claude Code — running interactively as `amadeus` — can push to
existing repos and create new public ones under `developmentbot/`.

Landed in `da538d4`. This file is a record, not a plan.

## What exists

| Thing | Where |
|---|---|
| Forgejo account | `developmentbot` / `developmentbot@homelab.local`, unrestricted, not admin |
| SSH key | `~/.ssh/id_ed25519` on `development`, owned by `amadeus`, registered as key `homelab-development` |
| API token | `development-host`, scopes `write:repository,write:user` |
| Token on host | `secrets/development-forgejo-token.age` → `/run/agenix/development-forgejo-token` (`0400 amadeus`), env-file `FORGEJO_TOKEN=…` |
| SSH client config | `programs.ssh.extraConfig` in `hosts/development/configuration.nix` |
| Commit identity | `programs.git.config` in the same file (`/etc/gitconfig`) |

Division of labour: **git uses the SSH key, the token is only for the REST API**
(creating repos). Losing either costs a re-mint, nothing more.

## Deliberate non-choices

- **The SSH key is NOT an agenix secret.** It is a local credential on a
  long-lived host; the repos live on Forgejo, so a wiped VM just generates a new
  key and re-registers it. (`hermes` does encrypt its key — different call,
  because that key is also the Obsidian vault's and the agent is unattended.)
- **No site-admin token was used.** `write:user` lets the bot register its own
  key via `POST /user/keys`, so nothing needed admin rights after account
  creation. The old plan's web-UI admin token step was unnecessary.
- **No collaborator automation.** Adding the bot to existing repos is done by
  hand in the web UI.
- **Key not shared with `hermes-bot`.** Forgejo resolves the account from the key
  fingerprint, so one public key belongs to exactly one account; sharing would
  couple the two hosts' revocation.

## Re-minting the token

The Forgejo CLI needs the DB password passed explicitly — the NixOS module feeds
it via a systemd credential that does not exist outside the unit — and the binary
is not on the login PATH. On `homelab-forgejo`:

```bash
FORGEJO_BIN=$(systemctl show forgejo -p ExecStart --value | grep -oP 'path=\K\S+')
DBPW=$(sudo cat /run/agenix/forgejo-db-password)
fj() {
  sudo -u forgejo env FORGEJO_WORK_DIR=/var/lib/forgejo \
    FORGEJO_CUSTOM=/var/lib/forgejo/custom FORGEJO__DATABASE__PASSWD="$DBPW" \
    "$FORGEJO_BIN" -c /var/lib/forgejo/custom/conf/app.ini "$@"
}

fj admin user generate-access-token --username developmentbot \
  --token-name development-host --scopes write:repository,write:user --raw
```

Then re-encrypt (from *inside* `secrets/` — AGENTS.md §6), keeping the
`FORGEJO_TOKEN=…` env-file shape, and `just colmena-apply-host development`.

## Creating a public repo

```bash
curl -s -X POST https://forgejo.homelab.local/api/v1/user/repos \
  -H "Authorization: token $FORGEJO_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"REPO","private":false}' | jq -r .ssh_url
```

## Gotchas hit while building this

- The SSH user is **`forgejo`**, not `git` — `git@` is silently rejected.
- `forgejo admin user create` has **no `--full-name` flag**; set the display name
  afterwards via `PATCH /api/v1/user/settings`.
- `POST /api/v1/admin/users/{u}/tokens` is **not a route** (404); the CLI
  `generate-access-token` is the way in, since `POST /users/{u}/tokens` needs
  basic auth and Pocket-ID accounts have no local password.
- `$FORGEJO_TOKEN` is exported by `environment.interactiveShellInit`, so it only
  appears in **interactive login shells** started after the deploy. Anything
  running non-interactively must read `/run/agenix/development-forgejo-token`.
- Swagger is at `/swagger.v1.json`, not `/api/swagger.v1.json`.
- After a reprovision the host key changes → `just get-host-key` +
  `just reencrypt`, or activation fails with `no identity matched any of the
  recipients` (AGENTS.md §6).
