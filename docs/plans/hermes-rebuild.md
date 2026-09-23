# Hermes Rebuild Plan — Wipe, XFS on ssd_pool, Multi-Profile, No API Server

Date: 2026-09-23
Status: plan only, nothing implemented.
Companion: `docs/hermes-agent-findings-2026-09-23.md` (upstream state, capability gaps).

## 1. What Changes

**Goal.** Destroy VM 4334 and rebuild hermes from scratch: XFS root on `ssd_pool`,
current upstream `hermes-agent`, several isolated agent profiles, reachable only as an
interactive agent over ssh/mosh plus moshi-hook push. Nothing from the old state dir
is migrated.

**In:**

- New blank disk on `ssd_pool`, `modules/disko-xfs.nix`, installer-ISO provisioning.
- `hermes-agent` unpinned to `v2026.9.21`.
- Profiles: `default`, `coding`, `research`, `kb` — separate `config.yaml`, `.env`,
  `SOUL.md`, memory, sessions and cron per profile.
- moshi-hook (per profile) + mosh/ssh over Tailscale as the *only* interfaces.
- MCP servers carried over: `axon-gateway`, `agentmail`.

**Out (deleted, not migrated):**

- The api_server, its Caddy vhosts, the step-ca/Tailscale cert wiring, port 443, and
  the `hermes-api-server-key` secret. Open WebUI stops being a client (§9).
- The Obsidian vault: `hermes-vault-git-setup`, `hermes-vault-bootstrap`,
  `OBSIDIAN_VAULT_PATH`, the `obsidian-vault-notes` skill and the SOUL.md sections
  that drive it.
- The homelab-repo feature-branch workflow: `hermes-repo-sync` + timer,
  `HOMELAB_REPO_PATH`, the `homelab-config-repo` skill, the `hermes-forgejo-ssh`
  secret, and the `nix`/`openssh` entries in `extraPackages` that existed for it.
- The `cron-result-delivery` skill (upstream delivers natively now — findings §4.4).
- `opencode` wrapper and `launch-hermes` (replaced by §6).

Everything dropped here is recoverable from git; this plan does not delete the old
`hosts/hermes/configuration.nix` history, it rewrites the file.

## 2. Infrastructure — `iac/main.tf`

Current `hermes_vm` (line ~594): 2 cores, 2048 MB dedicated / 1024 floating, **256 GB
disk on `zfs_pool`** imported from the Debian cloud image, `started = false`,
`on_boot = false`.

Target block:

```hcl
  cpu {
    cores = 4          # was 2 — several profiles + an agent loop + local tools
    type  = "host"
  }

  memory {
    dedicated = 6144   # pinned: floating == dedicated, no ballooning
    floating  = 6144
  }

  # ssd_pool + XFS, same reasoning as dns_vm/ca_vm. BLANK disk, no file_id:
  # importing a cloud image onto this zfspool fails with "no zvol device link
  # ... after 10 sec". The installer comes from the CD-ROM below.
  disk {
    datastore_id = "ssd_pool"
    interface    = "scsi0"
    size         = 48
    discard      = "on"
    file_format  = "raw"
  }

  cdrom {
    file_id   = "local:iso/nixos-homelab-<rev>-x86_64-linux.iso"
    interface = "ide0"
  }

  boot_order = ["scsi0", "ide0"]

  started = true
  on_boot = true
```

Notes:

- **Keep `vm_id = 4334`** and the resource name so DNS (192.168.2.155) and the
  Proxmox inventory output at line ~1562 stay valid.
- Dropping `file_id` and changing `datastore_id` on the disk is a **replacement**, not
  the in-place move the woodpecker block documents (that one kept its `file_id`).
  That is the intent here — confirm with `tofu plan` that it shows the disk replaced
  and the VM otherwise stable before applying.
- `size = 48`: no vault, no repo checkout, no podman images; what remains is the Nix
  store, per-profile session/memory SQLite, and logs. XFS grows but never shrinks and
  growing is a manual `growpart` + `xfs_growfs`, so this is deliberately more than the
  32 GB dns/ca use.
- `file_id` on the cdrom must match an ISO actually uploaded to `local` — `just
  iso-build` then re-upload; the string carries the nixpkgs rev and changes every time.
- `memory.floating == dedicated` follows the woodpecker finding: ballooning on this
  node has caused instability, and this guest is not a donor.

## 3. Filesystem — `modules/disko-xfs.nix`

`hosts/hermes/configuration.nix:268` imports `../../modules/disko-config.nix` (btrfs
subvolumes + swapfile). Swap the import to `../../modules/disko-xfs.nix`.

That module is the repo's documented default for new VMs and is the right answer here:
the guest disk is a zvol on a ZFS pool, so btrfs stacks a second CoW layer and a
second zstd compression pass on top of one that is already doing both. XFS also gives
a real 4 G swap partition (rather than a swapfile on a CoW subvolume), pins the disk by
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` instead of `/dev/sda`, and
enables weekly `services.fstrim` — which is why `discard = "on"` in §2 matters.

No host-specific override is needed: hermes has one disk at scsi0.

## 4. Upstream Bump

Lift the pin in `flake.nix` to the current release and drop the pin comment:

```nix
hermes-agent = {
  url = "github:NousResearch/hermes-agent/v2026.9.21";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The `registration_lifecycle` crash that caused the pin is fixed upstream and now has a
build-time regression check. Full detail, plus the three pre-bump checks (plugin import
decomposition, `hermesHomeFiles` vs `documents` for SOUL.md, gateway singleton lock),
is in the findings doc §2–§3. **Do those checks as part of this rebuild**, not after —
a wipe is the cheapest moment to discover that a plugin no longer loads.

Validate with a scoped eval only:

```bash
nix eval '.#nixosConfigurations.hermes.config.system.build.toplevel.drvPath'
```

Not `nix flake check` (evaluates ~16 hosts, OOMs), and leave the full `colmena build`
to a session that can absorb the compile.

## 5. Profiles

### 5.1 What upstream gives us

A profile is a complete second Hermes home at `$HERMES_HOME/profiles/<name>/` with its
own `config.yaml`, `.env`, `SOUL.md`, `memories/`, `sessions/`, `skills/`, cron jobs
and `state.db`. A named profile resolves providers **only** from its own `auth.json`
and `.env` — it never inherits the root profile's keys. So "different API keys per
profile" is native, not something we have to build.

Access: `hermes -p coding chat`, or the auto-generated `~/.local/bin/coding` wrapper
(which just sets `HERMES_HOME=…/profiles/coding`), or a sticky `hermes profile use`.

Hard rule from upstream, worth repeating in our config comments: **never point two
agent processes at the same profile home.** Both write memory, and each loads the
other's writes into its system prompt at session start.

### 5.2 Proposed profiles

| Profile | Purpose | Model | Toolsets |
| --- | --- | --- | --- |
| `default` | host multiplexer, cron, catch-all | `deepseek-v4-flash` | file, memory, skills, web, session_search |
| `coding` | code work in scratch checkouts | `deepseek-v4-pro` | + terminal, code_execution, delegation |
| `research` | reading, synthesis | `deepseek-v4-pro` | + web (search **and** extract, findings §4.1) |
| `kb` | notes / knowledge capture | `deepseek-v4-flash` | file, memory, skills, session_search |

Keep each toolset list minimal: every enabled toolset costs tool-schema tokens on every
LLM call, and `browser` in particular should stay off until it has an engine (findings
§4.2).

### 5.3 Making profiles declarative

The NixOS module is single-home: `stateDir`, `settings`, `documents`, `environment`,
`environmentFiles` all describe exactly one Hermes home. There is **no profile option**
upstream. So the profiles need a small local module, e.g. `modules/hermes-profiles.nix`:

- Input: an attrset `profiles.<name> = { settings, soul, environmentFiles, … }`.
- For each profile, render `config.yaml` (via `pkgs.writeText` + the same YAML shape
  the module uses) and `SOUL.md` into the Nix store.
- A root activation script installs them to
  `/var/lib/hermes/.hermes/profiles/<name>/`, `chown hermes:hermes`, and concatenates
  the profile's agenix secret files into that profile's `.env` (mode 0600) — the same
  pattern the upstream module already uses for the root home's `.env`.
- Bind each rendered `config.yaml` and `SOUL.md` read-only in the unit's
  `ReadOnlyPaths`, exactly as the current config does for the root profile, so the
  agent cannot rewrite its own prompt or model at runtime.

Two things to preserve from the current host while doing this:

- **The config.yaml integrity gate.** `hermes-config-check` exists because a malformed
  `config.yaml` makes Hermes fail *open* to built-in defaults (AGENTS.md §6). With N
  profiles there are N files that can be corrupted, so the check must loop over
  `profiles/*/config.yaml` too, not just the root one.
- **`secretNonce`.** Nothing about writing files at stable paths changes the unit
  definition, so a deploy does not restart the agent. Keep the nonce and bump it when
  any profile's config, SOUL or secret changes.

### 5.4 Gateways: exactly one, multiplexing

As of `v2026.9.21` there is a **host-wide singleton lock**: one `hermes gateway run`
per machine, full stop. A second gateway starts in observe-only mode. The mechanism is
a per-role flock plus a published rendezvous record (pid, port, protocol version, token
fingerprint, served-profile set).

So do **not** create one systemd unit per profile. Instead:

```yaml
# profiles/default/config.yaml (the root profile only)
gateway:
  multiplex_profiles: true
```

The default profile's gateway becomes the host multiplexer and serves every enabled
profile; profiles created later are picked up live without a restart. Per-profile
lifecycle is then `hermes -p coding gateway stop|start` (parking/unparking via a
`gateway.parked` marker), not a second process.

**Footgun to check:** the upstream module's `ExecStart` is
`hermes gateway run --replace`, and issue #119837 reports that `--replace` skips the
host-lock refusal — a supervised unit that loses a start race can end up running a
second gateway beside the multiplexer. With a single unit this is unlikely, but verify
`hermes gateway status` reports one owner after boot.

**Do we need the gateway at all?** With no chat platforms, no api_server and no
webhooks, its only remaining job is the 60 s cron tick. Two options:

- **Keep it** (recommended): one unit, `multiplex_profiles: true`, so scheduled jobs
  work across profiles and upstream's native cron delivery (findings §4.4) is available.
- **Drop it**: no `hermes-agent.service` at all, purely interactive `hermes -p … chat`
  over mosh. Simpler, but no schedules and no place for the moshi hooks to fire from
  outside a live session.

### 5.5 moshi-hook per profile

`moshi-hook install` writes into `$HERMES_HOME/.hermes/config.yaml` — i.e. into
*whichever* home `HERMES_HOME` points at. With four profiles that is four installs, and
four copies of the mixed-indent corruption footgun that `hermes-config-check` exists to
repair (AGENTS.md §6; `hosts/hermes/moshi-hook.nix`).

Keep the existing discipline and extend it:

- `plugins.enabled = ["moshi-hooks"]` stays **declarative per profile** in Nix.
- `moshi-hook install` runs once per `(profile, moshi-hook version)` pair, guarded by a
  per-profile stamp file, with `HERMES_HOME` set to that profile's directory.
- `hermes-config-check` repairs every profile's file afterwards (§5.3).
- Pairing (`moshi-hook pair --token`) is per host, not per profile, and stays a single
  oneshot.

**Blocker — the moshi token is not encrypted to this host.**
`secrets/secrets.nix:69` lists `moshi-device-id.age` recipients as
`[… hostDevelopment hostZeroclaw]` — **`hostHermes` is absent**, while
`hosts/hermes/configuration.nix:393` declares `age.secrets.moshi-device-id`. agenix
fails that secret softly (AGENTS.md: a decrypt failure records status and never aborts
the loop), and the pair script's own fallback is `"moshi-device-id secret unreadable,
skipping"` — which exits 0. The net effect is a host that never pairs, silently. Since
moshi-hook is now the primary interface, fix this first (§8).

Also unresolved and noted in the current config: it is **unverified whether one Moshi
account token can pair three hosts** (development, zeroclaw, hermes) simultaneously, or
whether pairing a new host invalidates the previous one. Verify on the rebuilt host
before assuming push works.

## 6. Access Path

No Caddy, no 443, no api_server. The host is reached as:

1. **mosh/ssh over Tailscale.** `modules/common.nix` already enables `programs.mosh`
   and opens udp 60000–61000, and `trustedInterfaces = ["tailscale0"]` covers the
   tailnet side. Firewall shrinks to `allowedTCPPorts = [22 9100]` (ssh + node
   exporter); drop 443.
2. **A login that lands directly in the agent.** The current `launch-hermes` wrapper
   does `sudo -u hermes bash -lc … exec hermes`, which needs a sudo hop from `amadeus`.
   Cleaner for a phone: give the `hermes` user the amadeus SSH key in its
   `authorized_keys` and log in as `hermes` directly, so the phone session is
   `mosh hermes@homelab-hermes` → `coding chat`. `hermes` is a non-sudo service user,
   which matches the agent-user split already used on `development`.
3. **moshi-hook** for push notifications out of agent sessions (§5.5).

Keep the agent OFF the `amadeus` account: `amadeus` has passwordless sudo, and the
agent runs a shell. The home-manager `programs.hermes-agent` route would be simpler but
puts an agent with a terminal tool inside a sudo-capable account — not an acceptable
trade here.

Per-profile shell wrappers (`coding`, `research`, `kb`) should be installed into the
hermes user's `~/.local/bin` (upstream creates these automatically on
`hermes profile create`; if we create profiles declaratively, add the wrappers in Nix
so they exist without an imperative step).

## 7. Memory — Requirement vs. What We Ship Now

**The requirement is not met by the deferred decision, and that is a deliberate
trade.** Recording it so the gap stays visible.

Hermes ships eight external memory providers. Their isolation model is *per profile by
default* — "each provider's data is isolated per profile", because each profile is a
separate home and the provider config lives in that home:

| Provider | Hosting | Infra needed | Cross-profile sharing |
| --- | --- | --- | --- |
| Holographic | local only | SQLite (+ NumPy for HRR) | no — one DB per home |
| ByteRover | local or cloud | local store `$HERMES_HOME/byterover/` | no — profile-scoped |
| **Honcho** | cloud **or self-hosted** | API + Deriver + Postgres/pgvector + Redis + an OpenAI-compatible LLM | **yes — native, shared `workspace` with one peer per profile** |
| Supermemory | cloud or self-hosted | own server | partial — multi-container mode, `enable_custom_container_tags` |
| Mem0 | cloud, self-hosted (Docker) or OSS | server or LLM + vector store | partial — via a shared `user_id`/`agent_id` |
| Hindsight | cloud or local | Postgres + LLM | not documented |
| OpenViking | self-hosted only | own server, no external DB | per-profile `.env` |
| RetainDB | cloud only | managed | no — auto profile-scoped projects |

**Now (this rebuild): holographic, per profile.** Two cheap mitigations that get part
of the way to a shared store without new infrastructure:

- The holographic provider takes a `db_path` config key. Pointing several profiles at
  one SQLite file is the low-cost approximation of a shared fact store. Treat it as
  experimental: upstream's warning is about two agents sharing a *home*, not a *DB*,
  and SQLite/WAL tolerates multiple processes — but nothing upstream promises this.
  If it is tried, only give it to profiles that will not run concurrently.
- Raise `memory.memory_char_limit` / `user_char_limit` further (the current host is
  already at 4× the module defaults, 8800/5500). This addresses "the memory is small"
  only in the sense of how much is injected into the prompt — it is not retrieval.

**Later (the real answer): self-hosted Honcho.** It is the only provider with native
cross-profile sharing — it models conversations as peers in a shared `workspace`, one
user peer plus one AI peer per profile, with config resolution `host block > root >
env > default` so shared settings are declared once. Config keys: `apiKey`, `baseUrl`,
`workspace`, `peerName`, `aiPeer`, plus per-host `recallMode`
(`hybrid`/`context`/`tools`) and `sessionStrategy`. Self-hosting runs API + Deriver +
Postgres/pgvector + Redis and routes LLM calls through any OpenAI-compatible endpoint
(our DeepSeek key qualifies).

When that is picked up, the open decision is placement: on the hermes VM itself
(self-contained, ~2 GB RAM, no new firewall holes) versus `hosts/containers` +
`hosts/database` (matches the existing homelab layout, but `postgresql_18` there has no
pgvector yet, there is no Redis, and hermes' unit-level `IPAddressAllow` needs entries
for both). Either way it is a separate plan.

## 8. Secrets

Recipients in `secrets/secrets.nix`, corrected for the new design:

| Secret | Action |
| --- | --- |
| `hermes-deepseek-key.age` | keep; likely split per profile (see below) |
| `hermes-opencode-zen-key.age` | keep if a profile uses opencode-zen, else drop |
| `hermes-agentmail-key.age` | keep (MCP carried over) |
| `axon-gateway-env.age` | keep **and add `hostHermes`** — line 42 currently lists `hostMcp hostDevelopment hostOtel hostZeroclaw` only |
| `moshi-device-id.age` | **add `hostHermes`** — line 69 omits it (§5.5) |
| `hermes-api-server-key.age` | delete — no api_server |
| `hermes-forgejo-ssh.age` | delete — no vault, no repo checkout |

Both "add `hostHermes`" items are pre-existing breakage, not new work created by this
rebuild: the config declares those secrets today and they cannot decrypt on that host.

**Per-profile keys.** Since a named profile reads only its own `.env`, giving profiles
different providers means one agenix file per profile, e.g.
`hermes-profile-coding-env.age`, `hermes-profile-research-env.age`, each holding that
profile's `DEEPSEEK_API_KEY` / `OPENCODE_ZEN_API_KEY` / etc. The profile module (§5.3)
concatenates them into `profiles/<name>/.env`.

**Re-key sequence after the wipe** (nixos-anywhere generates a fresh host key, so every
hermes secret fails to decrypt until this is done — AGENTS.md "Reprovisioned Host"):

```bash
just get-host-key 192.168.2.155     # or: ssh-keyscan -t ed25519 192.168.2.155
# update hostHermes = "ssh-ed25519 ..." in secrets/secrets.nix, and add hostHermes
# to axon-gateway-env + moshi-device-id while you are in there
just reencrypt                       # agenix -r
```

Hermes is also a Tailscale node, so the new host key must be in the `users` list that
receives `tailscale-auth-key.age`.

## 9. Cross-Host Cleanups

- **`hosts/containers/open-webui/default.nix`** — `OPENAI_API_BASE_URLS` (line 94)
  includes `https://hermes.homelab.local/v1`, and the surrounding comments describe
  hermes as a model backend reachable with the API server key. Remove the hermes entry
  and the key slot from the commented `open-webui-env` layout, leaving the wotan vLLM
  endpoint. Dropping the api_server without this leaves Open WebUI with a dead backend.
- **`hosts/dns/configuration.nix`** — keep the `hermes.homelab.{local,internal}` A
  records at 192.168.2.155 (still wanted for ssh/mosh) and the hosts-file entry.
- **`hosts/otel/*`** — the hermes blackbox probes were already removed on 2026-09-10;
  the `hermes-node` scrape job can come back once the host is up, since node exporter
  on 9100 stays.
- **`flake.nix`** — uncomment the `hermes` entry in `colmenaHive` (it was disabled
  2026-09-09 for "No route to host"). Until then only `nix eval` / `just deploy`
  reach this host, and `just cah hermes` does not work.

## 10. Cutover Runbook

1. `just iso-build`, upload the ISO to the `local` datastore, and update **both**
   `file_id` strings that reference it (dns, ca) plus the new hermes one.
2. Edit `iac/main.tf` (§2). `tofu plan` and confirm: hermes disk replaced, `vm_id`
   unchanged, no other guest touched. `tofu apply`.
3. Boot the VM from the ISO; note its DHCP address.
4. `just deploy hermes <ip> --phases disko,install,reboot` — skips kexec because the
   ISO is already an installer. This is the destructive step; the old 256 GB zvol is
   gone at this point.
5. Re-key secrets (§8). Nothing agenix-backed works before this.
6. Uncomment the hive entry (§9) and `just cah hermes`.
7. Verify, in this order:
   - `systemctl status hermes-config-check` → active/exited, no "repaired" surprises.
   - `journalctl -u hermes-agent -b | grep -c 'Falling back to default config'` → 0.
   - `hermes gateway status` → exactly one owner (§5.4).
   - `hermes profile list` → all four, each with its own model.
   - `sudo -u hermes hermes plugins compat …/profiles/<n>/plugins/moshi-hooks` → exit 0
     for each profile (findings §3.1).
   - `moshi-hook status --json | jq .paired` → `true`, and a test notification lands on
     the phone (§5.5).
   - `mosh hermes@homelab-hermes` from the phone → `coding chat` starts.
8. Only then remove the hermes backend from Open WebUI (§9) — that is the last thing
   still pointed at the old interface.

## 11. Open Questions

- **Gateway or no gateway** (§5.4) — decides whether cron exists at all on this host.
- **Which profiles actually get which provider/model**, and therefore how many
  per-profile secrets to create (§8). The table in §5.2 is a starting proposal.
- **Does one Moshi token pair three hosts?** Unverified, and this rebuild makes hermes
  the host that matters most (§5.5).
- **`hermesHomeFiles` vs `documents`** for SOUL.md on the new version (findings §3.2) —
  affects §5.3's activation script and the `ReadOnlyPaths` list. Check before writing
  the module, not after.
- **Coding profile without a repo checkout.** The homelab-repo workflow is deliberately
  dropped, so `coding` starts with no working tree, no `nix`/`openssh` on PATH and no
  Forgejo key. If that profile is meant to do real work, decide what it operates on.
