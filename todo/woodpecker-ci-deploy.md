# Woodpecker CI — remaining work before deploy

Woodpecker 3.16.0 runs on its **own new VM** — `woodpecker`, 192.168.2.182,
vm_id 4348 — served at `https://ci.homelab.local`. Config landed on branch
`feat/woodpecker-ci` (`hosts/woodpecker/configuration.nix`). This file is the
plan, not a record — nothing below has been done yet, and **the host will not
build until step 1 is complete**.

Native NixOS modules (`services.woodpecker-server` / `services.woodpecker-agents`),
not containers — the pinned nixpkgs ships exactly the 3.16.0 the podman-compose
prototype in `code/woodpecker-ci` ran.

**Why a dedicated VM rather than the forgejo host** (which is where that
prototype's README pointed): the agent reaches podman's socket, which is
effectively root on whatever machine it runs on, and a runaway pipeline would
otherwise contend for RAM and disk with the git forge. Server and agent share
this new VM so gRPC stays on loopback — it is authenticated by the shared secret
but **not encrypted**, so splitting them would put plaintext agent traffic on the
LAN and require opening port 9000. The forgejo host keeps exactly one
Woodpecker-related change: `webhook.ALLOWED_HOST_LIST`.

## 1. agenix secrets — BLOCKING, the host cannot build without these

`age.secrets.<n>.file` is a path literal, so a missing `.age` file is an eval
error, not a runtime one. Both files are referenced by
`hosts/woodpecker/configuration.nix`.

This is a **new host**, so its SSH host key must exist first — nixos-anywhere
generates a fresh one on every install, and agenix activation fails with
`no identity matched any of the recipients` without it. So this step happens
*after* step 4's install, not before:

```bash
just get-host-key 192.168.2.182
```

Add the key to `secrets/secrets.nix` as `hostWoodpecker` in the `let` block, and
**add it to the `users` list** — that is the recipient set for
`tailscale-auth-key.age`, which every host needs. Then, in the `keep-sorted`
block:

```nix
"woodpecker-agent-env.age".publicKeys = [amadeus amadeusAge hostWoodpecker];
"woodpecker-server-env.age".publicKeys = [amadeus amadeusAge hostWoodpecker];
```

Then create them (agenix **must** run from inside `secrets/`) and re-key
everything so the new host can read the shared secrets:

```bash
cd secrets
agenix -e woodpecker-server-env.age
agenix -e woodpecker-agent-env.age
just reencrypt   # agenix -r: re-encrypts every secret to current recipients
```

| File | Keys |
|---|---|
| `woodpecker-server-env.age` | `WOODPECKER_AGENT_SECRET`, `WOODPECKER_GRPC_SECRET`, `WOODPECKER_FORGEJO_CLIENT`, `WOODPECKER_FORGEJO_SECRET` |
| `woodpecker-agent-env.age` | `WOODPECKER_AGENT_SECRET` |

- `WOODPECKER_AGENT_SECRET` must be **byte-identical in both files**
  (`openssl rand -hex 32`). A mismatch is silent: the server starts, the UI looks
  healthy, and no pipeline is ever picked up.
- `WOODPECKER_GRPC_SECRET` ships with the literal upstream default `"secret"`.
  It signs the JWTs handed to agents — generate a second random value.
- The forge client/secret come from step 2.

## 2. Forgejo OAuth2 application — manual, no declarative API

In Forgejo → `/user/settings/applications` (or `/admin/settings/applications`),
create an app with redirect URI **exactly**:

```
https://ci.homelab.local/authorize
```

Copy the generated pair into `woodpecker-server-env.age` as
`WOODPECKER_FORGEJO_CLIENT` / `WOODPECKER_FORGEJO_SECRET`.

`WOODPECKER_HOST` is baked into this redirect *and* into every webhook Woodpecker
registers per-repo, so `ci.homelab.local` is effectively permanent — changing it
later means re-registering webhooks on every repo.

## 3. Prometheus — node metrics DONE, application metrics deferred

Already wired: `hosts/otel/configuration.nix` has a `woodpecker-node` job
scraping `192.168.2.182:9100`, and `hosts/woodpecker/configuration.nix` enables
the node exporter. Nothing to do for host-level metrics.

Still missing: Woodpecker's *application* metrics (queue depth, running/pending
pipelines). Its `/metrics` endpoint **does not exist unless**
`WOODPECKER_PROMETHEUS_AUTH_TOKEN` is set. To enable:

1. Add `WOODPECKER_PROMETHEUS_AUTH_TOKEN` to `woodpecker-server-env.age`.
2. Add a scrape config on otel with a bearer token — note this needs the token on
   the *otel* host too, so it wants its own `.age` file readable by prometheus,
   not just the woodpecker-side env file:

```nix
{
  job_name = "woodpecker";
  scheme = "https";
  metrics_path = "/metrics";
  authorization.credentials_file = config.age.secrets.woodpecker-metrics-token.path;
  static_configs = [
    {
      targets = ["ci.homelab.local"];
      labels = {instance = "woodpecker";};
    }
  ];
}
```

Deferred deliberately — it needs a third secret shared across two hosts. The
service is not unmonitored in the meantime: node metrics are scraped, and the
dashboard health check (already added) covers liveness.

## 4. Deploy sequence

This is a **new host**, so it follows the full provision path, not a plain
colmena apply. Ordering matters in two places, both called out below.

```bash
# 1. Provision the VM. State is in the Postgres backend, so init first (below).
cd iac && tofu init && cd ..
just iac-plan            # expect ONLY woodpecker_vm to be created
just iac-apply

# 2. DNS FIRST -- before the host exists is fine, and Caddy needs
#    ci.homelab.local to resolve before it can request its step-ca cert.
#    A failed ACME run can wedge into a badNonce storm.
just colmena-apply-host dns

# 3. Install NixOS. DESTRUCTIVE: disko wipes the disk. Use the DHCP address the
#    fresh VM came up on; it reboots onto 192.168.2.182.
ssh amadeus@<dhcp-ip> lsblk        # sanity-check disk targeting first
just deploy woodpecker <dhcp-ip>

# 4. Now do step 1 of this file (host key -> secrets.nix -> agenix -> reencrypt).

# 5. Full gates, then the home-manager/nixvim layer + secrets.
just fmt
just nixos-check
just colmena-build-host woodpecker   # the gate nixos-check does NOT cover
just colmena-apply-host woodpecker

# 6. Forgejo webhook allowlist, and the dashboard tile.
just colmena-apply-host forgejo
just colmena-apply-host containers
```

The `tofu init` is not optional. State lives in the Postgres backend
(`backend "pg" {}` in `iac/main.tf`, connection string from `PG_CONN_STR` in
`.env` via the justfile's `dotenv-load`). While validating this change the
providers were installed with `tofu init -backend=false`, which caches providers
without attaching the backend — so `tofu plan` will refuse with "Backend
initialization required" until a plain `tofu init` re-attaches it. Remote state
was never read or written by that, only the local `.terraform/providers` cache.

Note `just deploy` (not `deploy-minimal`): this host has a static IP, and
`deploy-minimal` would leave it on a DHCP lease that `colmena-apply-host` cannot
reach.

## 5. Post-deploy verification

- [ ] `systemctl status woodpecker-server woodpecker-agent-podman` — both active
- [ ] `journalctl -u woodpecker-agent-podman | grep -i "permission denied"` —
      **empty**. This is the one thing that cannot be validated offline: the
      agent reaches podman's rootful socket (`/run/podman/podman.sock`, group
      `podman`, mode 0660) as a static `woodpecker-agent` user with
      `DynamicUser`/`PrivateUsers` forced off. If it fails, the group is not
      landing — check `SupplementaryGroups` on the running unit.
- [ ] `journalctl -u woodpecker-agent-podman | grep "could not persist agent config"`
      — **empty**. If present, `WOODPECKER_AGENT_CONFIG_FILE` is not landing in
      the StateDirectory and the agent re-registers on every restart, piling up
      dead agents in the UI.
- [ ] `curl -sI https://ci.homelab.local` → 200/302, not 000 (000 = down or
      step-ca trust failure)
- [ ] Log in via Forgejo OAuth, enable a repo, push, confirm a pipeline runs
- [ ] Confirm the webhook actually fired — `ALLOWED_HOST_LIST` is set to
      `external,ci.homelab.local` on the **forgejo** host, but if a push produces
      no pipeline this is the first suspect (Forgejo blocks webhooks to private
      addresses by default and fails **silently**). Now that CI is on a different
      VM this is a genuine cross-host call, not a loopback one.
- [ ] `nix flake check` still passes with the new host registered (it evaluates
      every host, so a broken `woodpecker` entry breaks the shared gate)
- [ ] Live log view streams rather than appearing frozen (Caddy
      `flush_interval -1`)

## 6. Resource limits

The VM is **4 cores / 4096 MB / 100 GB** (`woodpecker_vm` in `iac/main.tf`).
Disk is generous up front on purpose: growing it later is a manual guest-side
operation (`growpart` + `btrfs filesystem resize`), not something `tofu apply`
does, and pipeline step images accumulate fast.

Caps in `hosts/woodpecker/configuration.nix`:

| Limit | Value | Why |
|---|---|---|
| `WOODPECKER_MAX_WORKFLOWS` | 2 | 2 × 1 GB leaves ~1.3 GB for the system |
| `..._LIMIT_MEM` / `_MEM_SWAP` | 1 GB / 1 GB | equal values disable swap growth |
| `..._LIMIT_CPU_QUOTA` | 300000 | 3 of 4 cores; one stays free for the UI |
| `..._DEFAULT/MAX_PIPELINE_TIMEOUT` | 30 / 60 min | upstream defaults are 60/120 |
| `virtualisation.podman.autoPrune` | weekly | images otherwise fill the disk |

These per-step-container limits are the only ones that bound a runaway job.
A `MemoryMax=` on the `woodpecker-agent-podman` unit would **not** work: the
agent asks podman to create step containers over the socket, so they are
podman's children and land in podman's cgroups, not the agent's.

Now that CI has its own VM, the failure mode of a runaway pipeline is a degraded
CI host rather than a degraded git forge — which is the whole point of the split.
`nix flake check` on this repo is still a heavy job (it evaluates ~16 hosts and
has been OOM-killed elsewhere); if it becomes a pipeline, watch the first runs
and raise the VM's memory rather than the per-step cap.

## 7. Known limitations

- Rootless-style `docker:dind` plugins do not work under podman. Use Buildah or
  Kaniko for image builds.
- Upstream's stance on podman is *"no official support ... it might work"*, so
  treat backend oddities as expected rather than misconfiguration. Cosmetic
  container-cleanup error spam in agent logs is a known upstream issue
  (woodpecker#4366) and is safe to ignore.
- If pipelines hang instead of finishing, check
  `/etc/systemd/journald.conf.d/*.conf` — a restrictive `MaxLevelStore` changes
  the podman socket's log-follow behaviour and the agent never sees a step
  finish (woodpecker#2035).
- sqlite is deliberate for now (CI history is cheap to rebuild, and it avoids a
  cross-host dependency on the database VM). It lives at
  `/var/lib/woodpecker-server/woodpecker.sqlite` and has **no backup job** —
  fine while it holds nothing irreplaceable; revisit if pipeline history starts
  mattering.
