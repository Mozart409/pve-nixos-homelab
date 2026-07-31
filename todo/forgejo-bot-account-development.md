# Forgejo bot account for `development` (SSH push/pull from Claude Code)

Give the `development` host (`hosts/development/configuration.nix`, 192.168.2.184)
its own Forgejo identity so Claude Code — running interactively as `amadeus` —
can clone this repo and push feature branches to
`amadeus/pve-nixos-homelab` over SSH. Mirrors the existing hermes model
(AGENTS.md §7): bot account + deploy-style SSH key, `main` stays branch-protected,
the user opens PRs and deploys by hand.

Status: **planned, nothing created or deployed.** No Forgejo account exists, no
secret, no Nix change.

## Current state (verified 2026-07-30 against the live instance)

- Forgejo **15.0.5** on `homelab-forgejo` / 192.168.2.178
  (`hosts/forgejo/configuration.nix`), Postgres backend on 192.168.2.134.
- SSH forge on **port 2222**, `START_SSH_SERVER = true`. The SSH login user is
  **`forgejo`**, not `git` — `git@` is silently rejected
  (`hosts/hermes/configuration.nix:49`).
- Local registration is off: `DISABLE_REGISTRATION = true` +
  `ALLOW_ONLY_EXTERNAL_REGISTRATION = true`; accounts come from Pocket ID via
  `oauth2_client.ENABLE_AUTO_REGISTRATION`. So a bot account **must** be created
  by an admin — it cannot self-register.
- Existing accounts: `amadeus`, `hermes-bot`. Repo `amadeus/pve-nixos-homelab`
  exists (API 200).
- `development` already imports `modules/step-ca-trust.nix` (so
  `https://forgejo.homelab.local` is trusted) and resolves `*.homelab.local` via
  the `dns` host. `claude-code` is already in `environment.systemPackages`.
- Swagger is served at `https://forgejo.homelab.local/swagger.v1.json` —
  **not** `/api/swagger.v1.json` (that 404s).

### API endpoints verified present on 15.0.5 (401 = exists, needs auth)

| Call | Result |
|---|---|
| `POST /api/v1/admin/users` | ✅ 401 |
| `POST /api/v1/admin/users/{username}/keys` | ✅ 401 |
| `PUT /api/v1/repos/{owner}/{repo}/collaborators/{collaborator}` | ✅ 401 |
| `POST /api/v1/repos/{owner}/{repo}/keys` (deploy key) | ✅ 401 |
| `POST /api/v1/users/{username}/tokens` | ⚠️ 403 — exists, needs **basic auth** |
| `POST /api/v1/admin/users/{username}/tokens` | ❌ 404 — not a Forgejo route |

## Decision: bot account (`claude-bot`) + its own SSH key, provisioned over REST

Everything except minting the first admin token is a REST call.

**Rejected — reusing `hermes-forgejo-ssh`.** Forgejo's SSH server resolves the
account from the key fingerprint, so a public key belongs to exactly one account.
Sharing the key would make development's pushes indistinguishable from hermes'
and couple the two hosts' revocation. `development` gets its own keypair.

**Rejected — repo deploy key** (`POST /repos/{owner}/{repo}/keys`,
`read_only: false`). Lighter (no account, repo-admin token is enough), but it is
per-repo and deploy keys interact badly with protected branches
(<https://codeberg.org/forgejo/forgejo/issues/1082>). Keep as the fallback if the
admin-token step turns out to be blocked.

**Note for later:** Forgejo 15's `CreateAccessTokenOption` has a `repositories`
array — *"creates an access token with access only to specified repositories"*.
Repo-scoped API tokens **do** exist (older community threads saying otherwise are
outdated). Useful if we later want Claude Code to open PRs itself rather than
just push branches; out of scope for v1 (SSH only, no API token on the host).

## Step 0 — admin token (the one manual, non-REST step)

`POST /api/v1/users/{username}/tokens` needs **HTTP basic auth with a local
password**. `amadeus` was auto-registered through Pocket ID and has no usable
local password, so that route is closed.

→ **Web UI → Settings → Applications → Generate New Token**, scopes
`write:admin` + `write:repository`.

⚠️ **Confirm `amadeus` is a site admin first** (Site Administration visible in the
user menu). The public API reports `is_admin: false` for every unauthenticated
lookup, so that reading proves nothing. If it is not admin, use the CLI fallback
below.

Header format is `Authorization: token <TOKEN>` (the literal word `token`, not
`Bearer`, for non-OAuth2 tokens).

## Step 1 — generate the keypair

Generate on the workstation (not on `development`) so the private key can be
agenix-encrypted into this repo and survive a reinstall:

```bash
ssh-keygen -t ed25519 -N '' -C 'claude-bot@homelab-development' \
  -f ~/.ssh/development-forgejo
```

## Steps 2–4 — provision over REST

```bash
F=https://forgejo.homelab.local/api/v1
T='Authorization: token <ADMIN_TOKEN>'

# 2. create the bot account
curl -s -X POST "$F/admin/users" -H "$T" -H 'Content-Type: application/json' -d '{
  "username": "claude-bot",
  "email": "claude-bot@homelab.local",
  "full_name": "Claude Code (development)",
  "password": "'"$(openssl rand -base64 32)"'",
  "must_change_password": false,
  "visibility": "private"
}'

# 3. attach the public key on behalf of that account
curl -s -X POST "$F/admin/users/claude-bot/keys" -H "$T" -H 'Content-Type: application/json' -d '{
  "title": "homelab-development",
  "key": "'"$(cat ~/.ssh/development-forgejo.pub)"'",
  "read_only": false
}'

# 4. grant write on the repo  (expect 204)
curl -s -o /dev/null -w '%{http_code}\n' \
  -X PUT "$F/repos/amadeus/pve-nixos-homelab/collaborators/claude-bot" \
  -H "$T" -H 'Content-Type: application/json' -d '{"permission":"write"}'
```

Schemas read from this instance's own swagger:
- `CreateUserOption` — required `username`, `email`; optional `password`,
  `full_name`, `must_change_password`, `restricted`, `visibility`, `login_name`,
  `source_id`, `send_notify`, `created_at`.
- `CreateKeyOption` — required `title`, `key`; optional `read_only`.
- `AddCollaboratorOption.permission` — enum `read | write | admin`.

⚠️ **`must_change_password` defaults to `true`** since Forgejo 7.0 and has a
history of being applied even when set false
(<https://codeberg.org/forgejo/forgejo/issues/9433>). Set it explicitly; it is
harmless for an SSH-only bot but avoids surprises if the account is ever used
interactively.

## Step 5 — Nix changes in this repo

1. **`secrets/secrets.nix`** — new entry next to the existing
   `development-opencode-zen-key.age` line:
   ```nix
   "development-forgejo-ssh.age".publicKeys = [amadeus amadeusAge hostDevelopment];
   ```
2. **Encrypt the private key** (from *inside* `secrets/` — AGENTS.md §6):
   ```bash
   cd secrets && agenix -e development-forgejo-ssh.age   # paste ~/.ssh/development-forgejo
   ```
3. **`hosts/development/configuration.nix`** — declare the secret and route SSH:
   ```nix
   # SSH private key for the claude-bot Forgejo account. Owned by amadeus
   # (not root) because ssh reads IdentityFile as the invoking user — Claude
   # Code runs interactively as amadeus. main is branch-protected on Forgejo,
   # so this key can push feat/* branches but never land changes directly.
   age.secrets.development-forgejo-ssh = {
     file = ../../secrets/development-forgejo-ssh.age;
     owner = "amadeus";
     mode = "0400";
   };

   # The SSH user is "forgejo" (the built-in Forgejo SSH server's RUN_USER),
   # NOT "git" — connecting as git@ is silently rejected. See AGENTS.md §7.
   programs.ssh.extraConfig = ''
     Host forgejo.homelab.local
       Port 2222
       User forgejo
       IdentityFile ${config.age.secrets.development-forgejo-ssh.path}
       IdentitiesOnly yes
       StrictHostKeyChecking accept-new
   '';
   ```
   ⚠️ The file's header is currently `{pkgs, ...}:` — add `config` to the
   argument set for `config.age.secrets…` to resolve.
4. **Commit identity** — `git commit` from `development` needs `user.name` /
   `user.email`. The home-manager layer in `flake.nix` only carries nixvim, so
   either set it by hand once on the host or add `programs.git.config` to the
   host config. Decide at implementation time; leaning "set it in Nix" so a
   reinstall keeps it.

Clone URL for the host:
```
ssh://forgejo@forgejo.homelab.local:2222/amadeus/pve-nixos-homelab.git
```

## Risks / gotchas

1. **`amadeus` may not be a site admin** — steps 2–3 need `write:admin`. Fallback
   is the CLI (below), which has its own trap.
2. **CLI fallback trap:** the NixOS forgejo module feeds the DB password via
   *systemd credentials* (`/run/credentials/forgejo.service/…`), which do not
   exist outside the unit. Running the admin CLI by hand therefore needs the
   password passed explicitly:
   ```bash
   sudo -u forgejo \
     FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/var/lib/forgejo/custom \
     FORGEJO__DATABASE__PASSWD="$(sudo cat /run/agenix/forgejo-db-password)" \
     forgejo admin user create --username claude-bot --email claude-bot@homelab.local \
       --random-password --must-change-password=false
   ```
   (`forgejo` is not on the login PATH — use the store path from
   `systemctl show forgejo -p Environment`.) There is **no** CLI subcommand for
   adding SSH keys; the key still has to go through the API or web UI.
3. **Wrong SSH user** — `git@forgejo.homelab.local` fails with no useful error.
   Must be `forgejo@`.
4. **Branch protection** must actually be configured on `main` for this repo
   (AGENTS.md §7 says it was done for `hermes-bot`; re-verify it blocks
   `claude-bot` too — protection is per-branch, not per-account, so it should).
5. **Key reuse** — do not paste hermes' public key; Forgejo will reject it as
   already in use, and sharing it would break per-host revocation.

## Rollout steps

1. Confirm `amadeus` is a site admin; mint the admin token (Step 0).
2. Generate the keypair (Step 1).
3. Run the three REST calls (Steps 2–4); verify with
   `curl -s $F/users/claude-bot` and
   `curl -s -H "$T" $F/repos/amadeus/pve-nixos-homelab/collaborators`.
4. Land the Nix change (Step 5): `just fmt`, then scoped eval
   `nix eval .#nixosConfigurations.development.config.system.build.toplevel.drvPath`
   (the full `just nixos-check` OOMs — AGENTS.md §7).
5. `just colmena-apply-host development`.
6. Revoke the admin token once provisioning is done — it is not needed at runtime.

## Verification (on `development`, as `amadeus`)

- `ssh -T forgejo@forgejo.homelab.local -p 2222` → Forgejo greets `claude-bot`.
- `git clone ssh://forgejo@forgejo.homelab.local:2222/amadeus/pve-nixos-homelab.git`
  succeeds without prompting.
- `git push -u origin feat/<slug>` succeeds; a push to `main` is **rejected** by
  branch protection.
- `ls -l /run/agenix/development-forgejo-ssh` → `0400 amadeus`.

## Remaining manual / external steps (not Nix)

- Mint + later revoke the admin token (web UI).
- Create `claude-bot`, attach the key, add the collaborator (REST).
- Verify `main` branch protection on `amadeus/pve-nixos-homelab`.
