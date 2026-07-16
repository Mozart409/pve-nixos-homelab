# hofvarpnir migration: old Rocky LXC → NixOS

Move hofvarpnir off the old docker-compose Rocky LXC (CT 100, `192.168.2.100`,
unprivileged) onto the homelab-native stack:

- **App** → `homelab-jellyfin` (`192.168.2.180`) as an OCI container, writing media
  straight to the local tuned ZFS `/media/hofvarpnir` (no NFS, no LXC mount wall).
- **DB** → `homelab-database` (`192.168.2.134`) central Postgres 18.
- Retires hofvarpnir, its embedded DB container, and the NFS link on the LXC. The LXC
  itself stays for now (tsbridge, node-exporter, syncthing still running).

**Why this over NFS:** the LXC is unprivileged → NFS mounts inside it are blocked at
the user-namespace level (`mount=nfs` feature does not lift it). Rather than mount NFS
on the PVE host + bind into the CT, co-locating hofvarpnir with the media pool removes
the cross-host problem outright.

**Live facts (verified 2026-07-16):**

| Fact | Value |
| --- | --- |
| DB host Postgres | `pkgs.postgresql_18` — dump/restore is same-major |
| jellyfin uid/gid | `999:999` (matches NFS `anonuid`/`anongid` and plan `user =`) |
| `/media/hofvarpnir` on jellyfin | empty (`tmpfiles` only); **46 GB still only on LXC** → rsync required |
| Current Prometheus scrape | `hofvarpnir.dropbear-butterfly.ts.net` (tsbridge) |
| Dashboard / uptime-forge | still point at `*.ts.net` |

## Status — 2026-07-16 (migration essentially complete)

- **Phases 0–2:** ✅ done. DB + role on homelab-database; app container on jellyfin;
  Caddy step-ca vhost. **OIDC (Pocket ID) wired in from the start** (added vs. original
  plan): `OIDC_*` env + a styled login button on both hofvarpnir and Jellyfin.
- **Phase 3 (cutover):** ✅ done — the old app had been **stopped the whole time**, so
  3.1/3.2 were trivial (the Phase 1 dump was already final). 46 GB `completed/` rsynced
  and chowned to `jellyfin` (999). 3.5 done — the now-unused NFS export + port 2049
  were removed from jellyfin config.
- **Phase 4:** ✅ 4.1 Prometheus scrape (target UP), Loki shipping (via plain
  `http://otel.homelab.local:3100`, NOT the step-ca vhost — rustls/webpki-roots),
  4.2 dashboard + uptime-forge repointed to `*.homelab.local`. ✅ **4.3 done — the
  entire CT 100 LXC was destroyed on PVE; ~700 GB ZFS reclaimed.**
- **Notable detours:** step-ca badNonce storm needed *serialized* cert issuance
  ([[caddy-stepca-badnonce-new-vhosts]]); reinstalled jellyfin needed Tailscale
  re-approval or `*.ts.net` peers (pocketid) wouldn't resolve → OIDC discovery failed
  ([[reinstalled-host-tailscale-reapproval]]); media rsync left files as uid 1000 →
  re-chowned to 999.

**Migration COMPLETE — nothing outstanding.** (all phases 0–4 done)

---

## Decisions (locked)

- Run as **OCI container** from `ghcr.io/mozart409/hofvarpnir:0.2.4` via
  `virtualisation.oci-containers` (matches `axon-gateway`, `uptime-forge`). Source
  also has a Nix flake (`/home/amadeus/code/rust/hofvarpnir`) if we ever want a native
  build, but container matches the other Rust apps here.
- Expose via **Caddy vhost on jellyfin** (drops tsbridge for this service).
- DB → central `homelab-database` (like forgejo/romm/buildbot).
- Hostname → **`hofvarpnir.homelab.local`** (step-ca), **LAN-only**. No tailnet
  vhost: `get_certificate tailscale` only issues for the node's own name
  (`homelab-jellyfin`), and once tsbridge is gone no node owns `homelab-hofvarpnir.*`,
  so a ts.net vhost can neither route nor get a cert. Reach it over Tailscale via
  MagicDNS/split-DNS to the `dns` host. A dedicated tailnet name = optional follow-up
  (tsnet/tailscale sidecar).
- `API_BASE_URL` → `https://hofvarpnir.homelab.local`.
- `DATABASE_URL` host → **`database.homelab.local`** + `?sslmode=disable` (podman DNS).
- Cutover drain → **wait for in-flight LXC downloads to finish**, then stop app →
  final DB dump → rsync.
- Media rsync → **`completed/` only** (skip `incomplete/`; partials start clean).
- File layout on disk: app still uses `completed/` + `incomplete/` under
  `/media/hofvarpnir` (bind-mounted at container `/var/lib/hofvarpnir/downloads`);
  only `completed/` is migrated from the LXC.

## Guiding principle

Build the new side **alongside the running old LXC**; cut over only after verifying;
decommission last. Nothing destructive until Phase 4. Old LXC stack is the rollback
path until Phase 4.3.

### Deploy order (hosts)

```
secrets (agenix) → database → dns → jellyfin → otel → containers
```

DNS **before** jellyfin so step-ca ACME for `hofvarpnir.homelab.local` can resolve.
`containers` (dashboard + uptime-forge) and `otel` can land after the app is up, but
before decommissioning the LXC scrape target.

---

## Current state (from the LXC `compose.yml`)

- `hofvarpnir`: image `ghcr.io/mozart409/hofvarpnir:0.2.4`, port 3000, HOST 0.0.0.0.
  - env: `MAX_CONCURRENT_DOWNLOADS=1`, `DOWNLOAD_TIMEOUT_HOURS=9`,
    `MAX_DOWNLOAD_ATTEMPTS=2`, `RATE_LIMIT_DELAY_SECS=600`,
    `RUST_LOG=info,hofvarpnir=info,sqlx=warn`,
    `DATABASE_URL=postgresql://postgres:postgres@hofvarpnir_db:5432/hofvarpnir`,
    `DEFAULT_OUTPUT_DIR=/var/lib/hofvarpnir/downloads`,
    `API_BASE_URL=https://hofvarpnir.dropbear-butterfly.ts.net`,
    `METRICS_ENABLED=true`, `LOKI_URL=…/loki`,
    `OTEL_EXPORTER_OTLP_ENDPOINT=http://homelab-otel…:4317` (grpc),
    `OTEL_SERVICE_NAME=hofvarpnir`, OIDC_* (all unset → OIDC disabled).
  - volume `./hofvarpnir:/var/lib/hofvarpnir/downloads` → `completed/` (46 GB) +
    `incomplete/` live under it (on the LXC; jellyfin side is empty).
- `hofvarpnir_db`: `postgres:18.4-alpine3.24`, DB `hofvarpnir`, creds `postgres/postgres`,
  volume `hofvarpnir_pg_data`, published `127.0.0.1:5432`.
- Also on the LXC (out of scope): tsbridge, node-exporter, syncthing.

### File touch list (repo)

| Path | Change |
| --- | --- |
| `secrets/secrets.nix` + new `.age` files | `hofvarpnir-db-password.age`, `hofvarpnir-env.age` |
| `hosts/database/configuration.nix` | role, DB, password oneshot, **backup list** |
| `hosts/dns/configuration.nix` | A + PTR for `hofvarpnir.homelab.local` → `.180` |
| `hosts/jellyfin/configuration.nix` | import podman + `hofvarpnir.nix`; Caddy vhost; drop NFS + 2049 |
| `hosts/jellyfin/hofvarpnir.nix` | **new** — OCI container + age secret |
| `hosts/otel/configuration.nix` | scrape target → `hofvarpnir.homelab.local` + `metrics_path` |
| `hosts/containers/homelab-dashboard/default.nix` | URL + quick link |
| `hosts/containers/uptime-forge/forge.toml` | `[endpoints.hofvarpnir]` addr |

---

## Phase 0 — Secrets + DNS (can run first, zero downtime)

- [x] **0.1 agenix secrets** — from **inside `secrets/`** (not repo root; see AGENTS.md):

  ```bash
  cd secrets
  # generate a strong password, then:
  agenix -e hofvarpnir-db-password.age   # bare password only
  agenix -e hofvarpnir-env.age           # see content below
  ```

  - `hofvarpnir-db-password.age` — recipients
    `[amadeus amadeusAge hostDatabase hostJellyfin]`.
    File content: the password alone (romm/forgejo pattern).
  - `hofvarpnir-env.age` — recipients `[amadeus amadeusAge hostJellyfin]`.
    File content (one line; Postgres has no TLS — match uptime-forge exporter):

    ```
    DATABASE_URL=postgresql://hofvarpnir:<password>@database.homelab.local:5432/hofvarpnir?sslmode=disable
    ```

    Fallback if podman DNS misbehaves: use `192.168.2.134` (romm style).
  - Edit `secrets/secrets.nix` publicKeys, then `just reencrypt`.

- [x] **0.2 DNS** — in `hosts/dns/configuration.nix` (keep-sorted blocks):

  - `local-data`: `''"hofvarpnir.homelab.local. A 192.168.2.180"''`
  - `local-data-ptr`: `''"192.168.2.180 hofvarpnir.homelab.local"''`

  Deploy: `just colmena-apply-host dns`. Verify from jellyfin:
  `getent hosts hofvarpnir.homelab.local` and `database.homelab.local`.

---

## Phase 1 — Database → `homelab-database`

- [x] **1.1 Compat check** — **done**: `services.postgresql.package = pkgs.postgresql_18`
  on the DB host. Source dump is PG 18.4 alpine — same major, safe.
- [x] **1.2 DB + role** — mirror romm in `hosts/database/configuration.nix`:

  - `age.secrets.hofvarpnir-db-password` (file + mode, owner postgres-readable)
  - `ensureDatabases` += `"hofvarpnir"`
  - `ensureUsers` += `{ name = "hofvarpnir"; ensureDBOwnership = true; }`
  - `systemd.services.postgresql-hofvarpnir-password` oneshot:
    - `after` / `requires` = `["postgresql.service"]` (+ `agenix.service` in after)
    - **not** `postgresql-ensure-users.service` (does not exist; same gotcha as romm)
    - `ALTER USER hofvarpnir WITH PASSWORD '…'`
  - `services.postgresqlBackup.databases` += `"hofvarpnir"` (easy to miss)

  pg_hba already allows `192.168.0.0/16` scram-sha-256 — no change needed.

- [x] **1.3 Deploy** — `just colmena-apply-host database`.
- [x] **1.4 Smoke** — from anywhere with network:

  ```bash
  psql "postgresql://hofvarpnir:<pw>@192.168.2.134:5432/hofvarpnir?sslmode=disable" -c '\conninfo'
  ```

- [x] **1.5 Migrate data (snapshot)** — on the LXC while old app still runs:

  ```bash
  docker exec hofvarpnir_db pg_dump -U postgres -Fc hofvarpnir > /tmp/hof.dump
  # copy to DB host, then:
  pg_restore --no-owner --role=hofvarpnir -d hofvarpnir /tmp/hof.dump
  ```

  App on the LXC can keep running — this is a snapshot; **final re-sync at cutover**
  (Phase 3.2) after stopping the old app.

---

## Phase 2 — App on `homelab-jellyfin` (OCI container)

- [x] **2.1 Import podman** — add `../../modules/podman.nix` to
  `hosts/jellyfin/configuration.nix` imports (enables podman +
  `oci-containers.backend = "podman"` + `defaultNetwork.settings.dns_enabled`).
  - **Add the podman bridge to the firewall** — put `"podman0"` (and `"podman1"` if
    the container gets its own network) into `networking.firewall.trustedInterfaces`
    on jellyfin, or the container → `aardvark-dns` path is dropped and DNS/bootstrap
    loops ([[harbor-podman-bridge-firewall-dns]]). Confirm whether `modules/podman.nix`
    already handles this; if not, add it here. This is what makes
    `database.homelab.local` resolve from inside the container.
- [x] **2.2 Module** — new `hosts/jellyfin/hofvarpnir.nix`, import it from
  `configuration.nix`. Mirror `hosts/containers/axon-gateway/default.nix`:

  ```nix
  virtualisation.oci-containers.containers.hofvarpnir = {
    image = "ghcr.io/mozart409/hofvarpnir:0.2.4";
    autoStart = true;
    # Loopback only — Caddy is the sole public path (axon/romm pattern).
    # Do NOT omit ports; without a publish, Caddy cannot reach the container
    # on a different network namespace.
    ports = ["127.0.0.1:3000:3000"];
    user = "999:999"; # jellyfin:jellyfin on host
    volumes = [
      "/media/hofvarpnir:/var/lib/hofvarpnir/downloads"
    ];
    environment = {
      MAX_CONCURRENT_DOWNLOADS = "1";
      DOWNLOAD_TIMEOUT_HOURS = "9";
      MAX_DOWNLOAD_ATTEMPTS = "2";
      RATE_LIMIT_DELAY_SECS = "600";
      RUST_LOG = "info,hofvarpnir=info,sqlx=warn";
      DEFAULT_OUTPUT_DIR = "/var/lib/hofvarpnir/downloads";
      API_BASE_URL = "https://hofvarpnir.homelab.local";
      METRICS_ENABLED = "true";
      # Prefer *.homelab.local (MagicDNS does not resolve between VMs).
      LOKI_URL = "https://loki.homelab.local/loki"; # confirm path vs current compose
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel.homelab.local:4317";
      OTEL_SERVICE_NAME = "hofvarpnir";
    };
    environmentFiles = [config.age.secrets.hofvarpnir-env.path];
  };

  age.secrets.hofvarpnir-env = {
    file = ../../secrets/hofvarpnir-env.age;
    mode = "0400";
    # rootful podman: systemd reads EnvironmentFile as root before launch
  };
  ```

  `/media/hofvarpnir` already exists via tmpfiles (`0755 jellyfin jellyfin`).

- [x] **2.3 Caddy vhost** — in `hosts/jellyfin/configuration.nix`, a single step-ca
  vhost (LAN-only; see the hostname decision above for why there's no ts.net vhost):

  ```nix
  virtualHosts."hofvarpnir.homelab.local" = {
    extraConfig = ''
      tls {
        ca https://ca.homelab.local:8443/acme/acme/directory
      }
      reverse_proxy localhost:3000
    '';
  };
  ```

  Firewall 443 already open. No path stripping — app serves `/metrics` and
  `/dashboard` at root. The old tsbridge name `hofvarpnir.dropbear-butterfly.ts.net`
  keeps hitting the LXC until Phase 3.1; after that it's gone with no replacement.

- [x] **2.4 Deploy** — `just colmena-apply-host jellyfin`.

- [x] **2.5 Verify (empty media OK)**

  - `systemctl status podman-hofvarpnir` (or `oci-hofvarpnir`) is active
  - container logs: DB connect OK, migrations OK
  - `curl -k https://hofvarpnir.homelab.local/dashboard` (or from a step-ca-trusted host)
  - probe write: touch a file as the container user under `/media/hofvarpnir` and
    confirm `ls -ln` shows `999:999`
  - **do not** stop the LXC app yet; both can coexist (new side writes only if you
    use the new UI)

---

## Phase 3 — Cutover (app stop → final DB → media → NFS off)

Order matters: **stop writers first**, then final DB dump, then media rsync, then
point clients at the new URL, then remove NFS.

- [x] **3.1 Drain + stop old app** (old app was already stopped for the whole migration) — on the LXC:

  ```bash
  # Wait until the UI shows no active downloads, then:
  docker compose stop hofvarpnir
  # leave hofvarpnir_db running for the dump + rollback
  ```

- [x] **3.2 Final DB re-sync** (N/A — app stopped throughout, so the Phase 1.5 dump was already final) — re-dump/restore over the Phase 1.5 snapshot so no
  download/job state is lost. Verify row counts if useful. Incomplete/partial
  rows may still exist in the DB even though we skip rsyncing `incomplete/` —
  expect the new app to reconcile or re-queue those; no media files for them.

- [x] **3.3 Migrate media** (46 GB rsynced; re-chowned to 999 — rsync had left uid 1000) — rsync **`completed/` only** (~46 GB) from LXC →
  jellyfin. Prefer agent-forward push (same pattern as movies/TV):

  ```text
  LXC:./hofvarpnir/completed/ → jellyfin:/media/hofvarpnir/completed/
  # trailing slash on both — contents land in completed/, not completed/completed/
  # do NOT rsync incomplete/
  ```

  Use `tmux`, `rsync -aHAX --info=progress2` (or `-P`). Then:

  ```bash
  chown -R jellyfin:jellyfin /media/hofvarpnir
  ```

  (Local ZFS — no NFS re-export quirks.)

- [x] **3.4 Restart new app + verify**

  - restart container; UI shows existing library; paths resolve under
    `/media/hofvarpnir/completed`
  - start a small test download → lands as `999:999` on ZFS
  - Jellyfin library that points at `/media/hofvarpnir` (or `…/completed`) rescans
  - metrics: `curl -s https://hofvarpnir.homelab.local/metrics | head`
  - logs/traces in Grafana (LOKI_URL / OTLP env)

- [x] **3.5 Remove NFS from jellyfin** — done: `services.nfs.server` + settings + port 2049 removed:

  - drop `services.nfs.server` (and `services.nfs.settings.nfsd` if only used for this)
  - drop firewall TCP `2049`
  - deploy `just colmena-apply-host jellyfin`
  - on LXC: unmount any leftover NFS mount of `192.168.2.180:/` if present

---

## Phase 4 — Peripherals + decommission

### 4.1 Prometheus scrape (`hosts/otel/configuration.nix`)

Prefer the step-ca local name (otel already trusts step-ca via
`modules/step-ca-trust.nix`; mirrors axon). Add `metrics_path` (missing today):

```nix
{
  job_name = "hofvarpnir";
  scheme = "https";
  metrics_path = "/metrics";
  static_configs = [{
    targets = ["hofvarpnir.homelab.local"];
    labels = { instance = "hofvarpnir"; };
  }];
}
```

Deploy: `just colmena-apply-host otel`. Confirm target UP in Prometheus.

### 4.2 Dashboard + uptime-forge (`hosts/containers/…`)

Canonical public links use **`.homelab.local`** (same as axon/romm). Tailnet URL
is available for human access but not required in forge/dashboard:

- [x] `homelab-dashboard/default.nix` — `hofvarpnir.url` + hofvarpnir/Jellyfin quick-links
  → `*.homelab.local` (also flipped the Jellyfin tile off ts.net)
- [x] `uptime-forge/forge.toml` — hofvarpnir + jellyfin `addr` → `*.homelab.local`
  (+ `skip_tls_verification = true`; uptime-forge is rustls/webpki-roots, no step-ca trust)
- [ ] Optional drive-by: jellyfin forge/dashboard entries still use
  `jellyfin.dropbear-butterfly.ts.net` / ts.net — fix only if desired (out of
  scope for cutover).
- Deploy: `just colmena-apply-host containers`

### 4.3 LXC cleanup — ✅ DONE (whole LXC destroyed)

Superseded the granular plan: the **entire CT 100 LXC was destroyed** on the PVE
host (not just the hofvarpnir parts). `pct destroy` removed the container's ZFS
dataset and the pool reclaimed **~700 GB immediately** — verified `zpool list` →
2.99 TB free / 17% used, no leftover `subvol-100-disk` datasets or snapshots.

- [x] `hofvarpnir` + `hofvarpnir_db` containers + `hofvarpnir_pg_data` volume — gone with the LXC
- [x] downloads bind dir — gone with the LXC (media already safe on jellyfin ZFS)
- [x] `mount=nfs` feature — moot (LXC destroyed)
- [x] ~700 GB ZFS disk reclaimed on `zfs_pool` (auto-freed on destroy, no TRIM needed)
- note: tsbridge / node-exporter / syncthing that also lived on CT 100 are gone too

---

## Risks / notes

- **DB major** — already PG 18 on both sides; still use `--no-owner --role=hofvarpnir`.
- **File ownership** — container `user = "999:999"`; verify probe file is
  `jellyfin:jellyfin`. Wrong uid → Jellyfin can't read new downloads.
- **Loopback publish required** — `ports = ["127.0.0.1:3000:3000"]`. "No host port"
  means no LAN bind, not "no ports key".
- **Podman DNS** — `database.homelab.local` via podman → host DNS → `dns` host.
  If it fails, pin `192.168.2.134` in `hofvarpnir-env.age`.
- **`sslmode=disable`** — central Postgres has no TLS; sqlx/libpq often default to
  prefer TLS and then fail oddly without this.
- **Tailnet URL goes away** — the old `hofvarpnir.dropbear-butterfly.ts.net`
  (tsbridge) has **no replacement**; access becomes `hofvarpnir.homelab.local`
  (step-ca, reachable over Tailscale via split-DNS to the `dns` host). Bookmarks/
  scripts on the ts.net name need updating; scrape/dashboard/uptime move to
  `hofvarpnir.homelab.local` in Phase 4. During Phase 2–3 the old tsbridge URL still
  hits the LXC until 3.1. A dedicated tailnet name is a possible follow-up (tsnet sidecar).
- **otel OTLP reachability** — the container pushes to `otel.homelab.local:4317`
  (gRPC); confirm the otel host's firewall accepts 4317 from the jellyfin host (it
  accepted from the LXC before, so likely already open).
- **Incomplete skipped** — DB may still reference partial downloads with no
  files on disk after rsync; treat as re-queue / cleanup on the new side.
- **46 GB rsync** — HDD pool contention; `tmux` + resumable rsync.
- **OIDC** disabled today — nothing to migrate. Future Pocket ID: register callback
  under `https://hofvarpnir.homelab.local/…`.
- **postgresqlBackup** — forgetting to add `hofvarpnir` means no nightly dump.
- **agenix cwd** — always `cd secrets` before `agenix -e …`.
- **Parallel run** — Phase 2 new container + Phase 1 DB snapshot can leave the new
  UI showing stale job state until 3.2; don't use the new UI as primary until cutover.
- **LOKI / OTEL URLs** — re-check compose values and rewrite any `*.ts.net` /
  `homelab-otel…` MagicDNS names to `loki.homelab.local` / `otel.homelab.local`.

## Rollback

Until Phase 4.3:

1. Stop the new container on jellyfin (`systemctl stop podman-hofvarpnir` / equivalent).
2. `docker compose start hofvarpnir` on the LXC (old DB volume still intact —
   Phase 1 only *copied* data).
3. Clients still on `hofvarpnir.dropbear-butterfly.ts.net` via tsbridge keep working
   if that path was never torn down.
4. If DNS/scrape/dashboard were already flipped, revert those deploys or temporarily
   re-point forge/dashboard at the ts.net URL.

After Phase 4.3 (LXC containers removed), rollback requires restoring the dump from
`postgresqlBackup` or a retained `/tmp/hof.dump` and re-rsyncing media — much harder.
Keep the LXC DB volume until soak is done.

## Acceptance checklist (cutover complete)

- [x] `https://hofvarpnir.homelab.local/dashboard` loads (step-ca trusted) + Pocket ID SSO
- [x] Existing completed media visible; ownership `999:999`
- [x] New download lands on ZFS under `/media/hofvarpnir/completed`
- [ ] Jellyfin library sees new files (user's manual library setup)
- [x] Prometheus `job=hofvarpnir` target UP on `hofvarpnir.homelab.local`
- [x] Logs (Loki via http://otel…:3100) + traces (OTLP) for `OTEL_SERVICE_NAME=hofvarpnir`
- [x] NFS export + port 2049 gone from jellyfin (deploy `jellyfin`)
- [x] Dashboard + uptime-forge repointed to `hofvarpnir.homelab.local` (deploy `containers`)
- [x] LXC removed — entire CT 100 destroyed, ~700 GB ZFS reclaimed
