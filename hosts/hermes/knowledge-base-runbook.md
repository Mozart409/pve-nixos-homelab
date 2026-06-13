# Hermes shared knowledge base — setup runbook

Hermes shares a knowledge base (notes, grocery lists, todos) with you through a
**git-synced Obsidian vault** hosted in Forgejo.

- **Storage / sync:** a Forgejo repo, cloned to `/var/lib/hermes/workspace/vault`
  on the `hermes` host.
- **Agent access:** Hermes' bundled `note-taking/obsidian` skill reads/edits the
  markdown files via its native file tools, pointed at `OBSIDIAN_VAULT_PATH`.
- **Your access:** edit the same repo from Obsidian (obsidian-git plugin) or `jj`.
- **Bidirectional sync:** a systemd timer on `hermes` runs `hermes-vault-sync`
  every ~90s — commit local agent edits → `git pull --rebase` → `git push`.

The declarative half lives in `hosts/hermes/configuration.nix`. The steps below
are the **one-time manual setup** that can't be expressed in Nix (creating the
Forgejo account/repo and minting the deploy key).

> Adjust `vaultOwner` / `vaultRepoName` in `configuration.nix` if you use a
> different repo than `amadeus/obsidian-kb`.

> **Two gotchas that cost real time — read these first:**
> 1. **SSH user is `forgejo`, not `git`.** Forgejo's built-in SSH server only
>    accepts its configured user and *silently* rejects any other username with
>    `Permission denied (publickey)` and **no log line, even at Trace**. The
>    remote must be `ssh://forgejo@…`, which is why `vaultRemote` uses it.
> 2. **Don't encrypt with `EDITOR="cp …" agenix -e`.** This agenix build does not
>    shell-split `$EDITOR`, so `cp` never runs and you get a valid-looking but
>    *empty* `.age` (~420 B). The decrypted key then fails with
>    `Load key … error in libcrypto: unsupported`. Paste into the editor instead,
>    and sanity-check the size (`wc -c` ≈ 800 B for a real ed25519 key).

---

The bot account is registration-OIDC-only and **cannot log into the web UI**, so
everything below is done from the CLI on the Forgejo host plus the admin API —
no clicking around. On NixOS the `forgejo` binary isn't on `$PATH` and the DB
password is a systemd credential, so first grab both from the running unit:

```sh
ssh homelab-forgejo
FJ=$(systemctl show forgejo -p ExecStart --value | grep -oE '/nix/store/[^ ]*/bin/forgejo' | head -1)
ENV="FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/var/lib/forgejo/custom \
     FORGEJO__DATABASE__PASSWD__FILE=/run/credentials/forgejo.service/FORGEJO__DATABASE__PASSWD__FILE"
fj() { sudo -u forgejo env $ENV "$FJ" "$@"; }   # admin CLI helper
API=http://localhost:3000/api/v1                # HTTP_PORT from app.ini [server]
```

## 1. Create the `hermes-bot` Forgejo account

```sh
fj admin user create \
  --username hermes-bot --email hermes-bot@homelab.local \
  --random-password --must-change-password=false --admin=false
```

(The random password is irrelevant — the bot only ever authenticates by SSH key.)

## 2. Create the repo + collaborator + deploy key via the admin API

`hermes-bot` can't use the web UI, so script it with a **short-lived admin token**
for your own account. The deploy keypair is generated on your workstation; pass
its public half to the Forgejo host.

```sh
# --- on your workstation: generate the dedicated keypair (no passphrase) ---
ssh-keygen -t ed25519 -f /tmp/hermes-forgejo -N "" -C "hermes-bot@homelab"
PUB="$(cat /tmp/hermes-forgejo.pub)"

# --- on homelab-forgejo (fj/ENV/API from the preamble), with $PUB available ---
TOKEN=$(fj admin user generate-access-token --username amadeus \
          --token-name kb-setup --scopes all | grep -oE '[a-f0-9]{40}')
auth="Authorization: token $TOKEN"

# repo (owned by you, auto-initialized so it has a default branch)
curl -s -X POST "$API/admin/users/amadeus/repos" -H "$auth" \
  -H 'Content-Type: application/json' \
  -d '{"name":"obsidian-kb","private":true,"auto_init":true,"default_branch":"main"}'

# grant hermes-bot Write access
curl -s -X PUT "$API/repos/amadeus/obsidian-kb/collaborators/hermes-bot" \
  -H "$auth" -H 'Content-Type: application/json' -d '{"permission":"write"}'

# register the deploy PUBLIC key on hermes-bot (inline JSON; pass $PUB via env so
# spaces in the key aren't re-split by ssh/shell)
curl -s -X POST "$API/admin/users/hermes-bot/keys" -H "$auth" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"hermes-deploy\",\"key\":\"$PUB\"}"
```

Now **revoke the throwaway token**. The token-delete API requires *basic* auth
(not token auth) and your OIDC account has no local password, so delete it
straight from Postgres (local socket, peer auth):

```sh
sudo -u postgres psql -d forgejo -c "DELETE FROM access_token WHERE name='kb-setup';"
```

> The repo is created with just an auto-init `README.md`. Seeding `groceries.md`
> / `todos.md` / `.obsidian/` is optional — the agent's `obsidian` skill creates
> files as needed. To seed manually, clone with the **`forgejo@`** user:
> `git clone ssh://forgejo@forgejo.homelab.local:2222/amadeus/obsidian-kb.git`

## 3. Encrypt the bot's private key with agenix

```sh
# recipients are already declared in secrets/secrets.nix:
#   "hermes-forgejo-ssh.age".publicKeys = [amadeus amadeusAge hostHermes];
# agenix resolves ./secrets.nix relative to CWD, so you MUST be inside secrets/
# (see AGENTS.md).
cd secrets
agenix -e hermes-forgejo-ssh.age      # empty editor opens → paste the FULL
                                       # -----BEGIN OPENSSH PRIVATE KEY----- block,
                                       # save, quit. (NOT the EDITOR=cp trick.)
cd ..
wc -c secrets/hermes-forgejo-ssh.age  # sanity: ~800 B for a real key, not ~420

shred -u /tmp/hermes-forgejo /tmp/hermes-forgejo.pub
```

## 4. Deploy

```sh
git add secrets/hermes-forgejo-ssh.age hosts/hermes/configuration.nix \
        secrets/secrets.nix hosts/hermes/knowledge-base-runbook.md
just fmt
just nixos-check          # fails until the .age file exists (step 3) and is staged
just colmena-apply-host hermes
```

`config-only` changes may not restart the agent (see AGENTS.md). After deploy:

```sh
ssh homelab-hermes
sudo systemctl restart hermes-agent
```

## 5. Verify

```sh
ssh homelab-hermes
# Setup + first sync ran:
systemctl status hermes-vault-git-setup.service hermes-vault-sync.service
# Vault cloned:
sudo ls -la /var/lib/hermes/workspace/vault
# Force a sync cycle and watch logs:
sudo systemctl start hermes-vault-sync.service
journalctl -u hermes-vault-sync.service -n 30 --no-pager
```

Then, in Open WebUI (the `hermes-agent` model), ask:
*"What's on my grocery list?"* and *"Add milk to the grocery list."* Confirm the
change lands in Forgejo within ~90s, and that an edit you make in Obsidian shows
up on the next question.

## Operational notes

- **Conflicts:** both you and the bot push to one branch. `pull --rebase` +
  small commits handle the common case. If `hermes-vault-sync` logs a rebase
  conflict, resolve it manually in `/var/lib/hermes/workspace/vault` (as the
  `hermes` user) — the timer leaves the tree clean (`rebase --abort`) so nothing
  is lost.
- **Freshness:** the timer interval (`OnUnitActiveSec=90s`) is the lag knob.
  SOUL.md also nudges the agent to `git pull --rebase` before a read if needed.
- **Structured lists:** keep todos/lists as markdown checkboxes (Obsidian Tasks
  plugin works great). Do **not** use Hermes' built-in `kanban`/`todo` tools for
  shared lists — those persist in `HERMES_HOME`, not the vault, so they won't
  appear in Obsidian.
