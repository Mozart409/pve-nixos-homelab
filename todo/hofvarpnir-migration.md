# hofvarpnir migration: old Rocky LXC → NixOS

Move hofvarpnir off the old docker-compose Rocky LXC (CT 100, `192.168.2.100`,
unprivileged) onto the homelab-native stack:
- **App** → `homelab-jellyfin` (`192.168.2.180`) as an OCI container, writing media
  straight to the local tuned ZFS `/media/hofvarpnir` (no NFS, no LXC mount wall).
- **DB** → `homelab-database` central Postgres.
- Retires the old LXC entirely (was the end goal of the Jellyfin migration).

**Why this over NFS:** the LXC is unprivileged → NFS mounts inside it are blocked at
the user-namespace level (`mount=nfs` feature does not lift it). Rather than mount NFS
on the PVE host + bind into the CT, co-locating hofvarpnir with the media pool removes
the cross-host problem outright.

## Decisions (locked)
- Run as **OCI container** from `ghcr.io/mozart409/hofvarpnir:0.2.4` via
  `virtualisation.oci-containers` (matches `axon-gateway`, `uptime-forge`). Source
  also has a Nix flake (`/home/amadeus/code/rust/hofvarpnir`) if we ever want a native
  build, but container matches the other Rust apps here.
- Expose via **Caddy vhost on jellyfin** (drops tsbridge).
- DB → central `homelab-database` (like forgejo/romm/buildbot).

## Open question
- [ ] **Hostname.** Proposed `hofvarpnir.homelab.local` (step-ca, matches
  `jellyfin.homelab.local`). Dropping tsbridge loses the dedicated
  `hofvarpnir.dropbear-butterfly.ts.net` node — if a tailnet URL is wanted, add
  Tailscale Serve as a follow-up. `API_BASE_URL` must be updated to whatever we pick.

## Guiding principle
Build the new side **alongside the running old LXC**; cut over only after verifying;
decommission last. Nothing destructive until Phase 3.

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
    `incomplete/` live under it.
- `hofvarpnir_db`: `postgres:18.4-alpine3.24`, DB `hofvarpnir`, creds `postgres/postgres`,
  volume `hofvarpnir_pg_data`, published `127.0.0.1:5432`.
- Also on the LXC (out of scope): tsbridge, node-exporter, syncthing.

---

## Phase 1 — Database → `homelab-database`
- [ ] **1.1 Compat check** — confirm the DB host's Postgres version ≥ 18 (source dump
  is PG 18). `ssh amadeus@homelab-database 'psql --version'` / check
  `services.postgresql.package`. If older, dump with `--no-owner --no-privileges` and
  watch for incompatibilities.
- [ ] **1.2 agenix secret** — `secrets/hofvarpnir-db-password.age`, recipients
  `[amadeus amadeusAge hostDatabase hostJellyfin]` in `secrets/secrets.nix`; `just reencrypt`.
- [ ] **1.3 DB + role** — add `hofvarpnir` database + role on `homelab-database`,
  reusing the romm/forgejo pattern (`hosts/database/…`). **Watch the password-setter
  service-dep bug** ([[postgresql-password-service-dep]]): the password oneshot must
  depend on `postgresql.service`, not the nonexistent `postgresql-ensure-users.service`.
- [ ] **1.4 Deploy** — `just colmena-apply-host database`.
- [ ] **1.5 Migrate data** — on the LXC:
  `docker exec hofvarpnir_db pg_dump -U postgres -Fc hofvarpnir > /tmp/hof.dump`,
  copy to the DB host, `pg_restore --no-owner --role=hofvarpnir -d hofvarpnir /tmp/hof.dump`.
  (App on the LXC can keep running during this — it's a snapshot; final re-sync at cutover
  if needed.)

## Phase 2 — App on `homelab-jellyfin` (OCI container)
- [ ] **2.1 Import podman** — ensure `modules/podman.nix` is imported by
  `hosts/jellyfin/configuration.nix` (check what it provides first).
- [ ] **2.2 Container** — `virtualisation.oci-containers.containers.hofvarpnir`
  (new `hosts/jellyfin/hofvarpnir.nix`, mirror `hosts/containers/axon-gateway/default.nix`):
  - image `ghcr.io/mozart409/hofvarpnir:0.2.4`
  - `user = "999:999"` so downloaded files are `jellyfin:jellyfin` (readable by Jellyfin)
  - volume `/media/hofvarpnir:/var/lib/hofvarpnir/downloads`
  - env: same as current except `DATABASE_URL` → `homelab-database` (password from the
    agenix `environmentFile`, not inline), `API_BASE_URL` → new hostname. OIDC unset.
  - no host port exposed (Caddy proxies `localhost:3000`).
- [ ] **2.3 Secret env** — agenix `environmentFile` on jellyfin holding the DB URL /
    password (reuse `hofvarpnir-db-password.age` or a dedicated env file).
- [ ] **2.4 Caddy vhost** — add to `services.caddy.virtualHosts` in
  `hosts/jellyfin/configuration.nix`: `hofvarpnir.homelab.local` (step-ca) →
  `reverse_proxy localhost:3000`. Firewall 443 already open.
- [ ] **2.5 Deploy** — `just colmena-apply-host jellyfin`. Verify hofvarpnir comes up,
  connects to the migrated DB, dashboard loads at the new URL (writes to empty
  `/media/hofvarpnir` for now).

## Phase 3 — Data + cutover
- [ ] **3.1 Stop old app** — on the LXC `docker compose stop hofvarpnir` (leave DB +
  container in place for rollback).
- [ ] **3.2 Final DB re-sync** (only if 1.5 was taken well before cutover) — re-dump/restore
  so no download state is lost.
- [ ] **3.3 Migrate media** — rsync the 46 GB `completed/` (+ `incomplete/` if wanted)
  from the LXC → `jellyfin:/media/hofvarpnir/…` (agent-forward push like movies/TV;
  slow HDD pool), preserving the `completed/`/`incomplete/` layout the app expects.
  `chown -R jellyfin:jellyfin` after.
- [ ] **3.4 Restart + verify** — restart the container; confirm DB state intact, existing
  downloads visible in the UI, new downloads land in `/media/hofvarpnir/completed`, and
  the Jellyfin hofvarpnir library indexes them.

## Phase 4 — Peripherals + decommission
- [ ] **4.1 otel** — update the `hofvarpnir` Prometheus scrape target in
  `hosts/otel/configuration.nix` (currently `hofvarpnir.dropbear-butterfly.ts.net`) to
  the new endpoint; Loki/OTLP push env already points at homelab-otel.
- [ ] **4.2 dashboard** — update the hofvarpnir URL in
  `hosts/containers/homelab-dashboard/default.nix` (quick_link + `hofvarpnir.url`).
- [ ] **4.3 Decommission** — after a bake period, stop/remove the old LXC (or at least
  hofvarpnir + its DB there). Reclaim CT 100. Revert the temporary
  `pct set 100 --features nesting=1,mount=nfs` back to `nesting=1`.

---

## Risks / notes
- **DB version compat** (1.1) — PG 18 dump into an older server can fail; check first.
- **File ownership** — container must write as uid 999 (2.2) or Jellyfin can't read the
  media; verify a probe file lands `jellyfin:jellyfin`.
- **Lost tailnet hostname** — dropping tsbridge removes `hofvarpnir.*.ts.net`; decide
  whether Tailscale Serve is needed (open question above).
- **46 GB migration is slow** — same HDD-pool contention as the movies/TV copies; run in
  `tmux`, `-P` resumes.
- **OIDC** currently disabled (issuer unset) — nothing to migrate there. If you later add
  Pocket ID, the redirect base URL must match the new hostname.

## Rollback
Old LXC stack stays intact until Phase 4. To roll back before decommission: `docker
compose start hofvarpnir` on the LXC and repoint DNS/clients — the old DB container still
holds its data (Phase 1 only *copied* it).
