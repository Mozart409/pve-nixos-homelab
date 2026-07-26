# PostgreSQL backup layer — pgBackRest (replaces pg_dump)

Give the `database` host (`hosts/database/configuration.nix`, PG18 @
192.168.2.134) a real, application-consistent backup layer: **pgBackRest**
(physical, WAL-based, validated, off-site to R2). It becomes the primary DB
backup — pg_dump is not treated as a backup tool. The existing
`services.postgresqlBackup` is **kept running in parallel through the transition**
and removed once the first pgBackRest restore is rehearsed.

Status: **planning / ready to implement after commit.** Nothing deployed.

## Current state (verified)
- **DB backup today:** `services.postgresqlBackup` — daily 03:00 `pg_dump`, zstd,
  `/var/backup/postgresql` (`hosts/database/configuration.nix:260`). **Kept in
  parallel during transition**, removed after the first pgBackRest restore drill.
- **Whole-VM:** the DB VM is backed up to **PBS → Cloudflare R2** (crash-
  consistent VM image, off-site). Configured at the Proxmox/PBS layer, not in
  this repo.
- Filesystem **Btrfs**; PGDATA forced NoCoW (`+C`, tmpfiles).
- **All VMs share one ZFS pool on one Proxmox host.** This is the decisive
  constraint: any backup target that lives on a homelab VM (local-posix on the DB,
  or Garage on `cache`) is on the *same pool/host* as the DB → same failure
  domain. Pool/host loss takes the DB and the "backup" together. **The only
  durable copy is one that leaves the pool** → Cloudflare R2.
- **Object storage available but not useful as a backup target:** `hosts/cache`
  runs **Garage** (S3-compatible, single node, `replication_factor = 1`) @
  192.168.2.175. Rejected as a repo — same ZFS pool as the DB (above), so no
  durability gain over local-posix.

## What this closes
1. **No PITR** — the pg_dump layer only recovers to last night's dump (~24 h
   RPO), can't recover to just before a bad migration / accidental DELETE.
2. **No validated, DB-aware backup** — the PBS VM image is only *crash-
   consistent*: it restores like a power-loss (Postgres replays WAL) *only if the
   snapshot is atomic*, can't do PITR, can't restore a single DB, and carries any
   latent corruption block-for-block with no validation. Good DR, not a DB
   backup. (Verify PGDATA+WAL are on one virtual disk and qemu-guest-agent
   quiescing is on, or the VM snapshot can tear.)

## Decision: pgBackRest via the native NixOS module, as the sole DB backup layer

**Adopt `services.pgbackrest`; keep `services.postgresqlBackup` until the first
restore drill succeeds, then remove it.** The module is a first-class citizen in
our pinned nixpkgs — verified:
`nix eval .#nixosConfigurations.database.options.services.pgbackrest.enable`
→ "Whether to enable pgBackRest." (`nixos/modules/services/backup/pgbackrest.nix`
in our pin.)

What `enable = true` gives us automatically (read from the pinned module):
- Adds `pkgs.pgbackrest`, generates `/etc/pgbackrest/pgbackrest.conf`, creates
  the `pgbackrest` user/group with cross-membership to `postgres`.
- **Auto-configures `stanzas.default`** for the local cluster
  (`instances.localhost = { path = postgresql.dataDir; user = "postgres"; }`) —
  we only add `jobs` + a repo.
- **Wires PostgreSQL:** `archive_mode = "on"` (mkDefault) +
  `archive_command = '<abs>/pgbackrest --stanza=default archive-push "%p"'`
  (absolute store path). Stanza is hardcoded `default`.
- Each `jobs.<name>` → oneshot service (runs as `pgbackrest`) with idempotent
  `stanza-create` as `ExecStartPre` + timer.
- Sets `identMap`, `commands.restore.lock-path=/tmp/postgresql`,
  `initdbArgs=["--allow-group-access"]` (⚠ no effect on our existing cluster —
  Risks #1).

PG18 needs no `wal_level`/`max_wal_senders` change (defaults suffice). 25.05's
`pkgs.pgbackrest` is ≥2.54 (PG18-capable).

### Tradeoff of dropping pg_dump (acknowledged, accepted — after drill)
pgBackRest is whole-cluster and restores only to the **same major version**; it
can't do the single-table / cross-version "logical" restore pg_dump could. This
is an accepted tradeoff — the whole-VM PBS→R2 image remains as a coarse fallback,
and pgBackRest gives us PITR + validation the dump never did.

## Repo target: Cloudflare R2 directly (single repo)

Given the shared-ZFS-pool constraint, this is settled rather than a menu:
pgBackRest → **R2 as an S3 repo** is the only target that leaves the pool/host.
Off-host + off-site, **independent of the VM→PBS→R2 path**, PITR, client-side
encrypted. R2 credentials already exist (you use R2 today). Config:
`repo-type=s3`, endpoint `https://<accountid>.r2.cloudflarestorage.com`,
`region=auto`, `s3-uri-style=path`. This alone makes the DB backup real 3-2-1.

Rejected: **Garage** and **local-posix** — both sit on the same ZFS pool as the
DB, so neither is a second copy in any failure that matters.

Repo attr name `r2` with `type = "s3"` is safe: the module only defaults
`repo-host` for posix/sftp repos; S3 leaves `host` null.

### R2 durability / immutability posture (decided)
**Versioning + lifecycle, not Object Lock.** Object Lock (WORM) would break
pgBackRest's own retention — `pgbackrest expire` deletes expired backups, and
COMPLIANCE-mode locks make objects undeletable → repo grows unbounded + expire
errors. Instead, for real protection against fat-fingered `expire` and a
compromised R2 key on the DB host:
- **Bucket versioning ON** + an **R2 lifecycle rule** retaining *noncurrent*
  versions ~14 days then purging. A delete just drops a marker; the object is
  recoverable for 14 days. Doesn't fight pgBackRest expiration.
- **Scope the R2 API token to this one bucket** (Object Read & Write) so a DB-host
  compromise can't reach the PBS→R2 VM images or anything else in the account.
- **Client-side `aes-256-cbc`** (below) — Cloudflare can't read contents.
- True WORM, if ever wanted, = a *second* copy to a lock-enabled target under a
  *different* credential. Out of scope for now.

**Correlated risk (accepted):** PBS VM images and pgBackRest both land in the
same Cloudflare account. Homelab-acceptable; the only shared failure is "CF
account gone."

### Retention: 2 full, not 1
Goal is "restore current state," not deep PITR — so retention is small. **But
keep `retention-full = 2`, not 1.** retention isn't about time-travel; it's about
how many *independent restore bases* exist. Every diff/incr depends on its full,
so with a single full a silently-corrupt or unreadable base = total loss with no
fallback. A second full is cheap (small DBs, cheap R2) and is the difference
between one bad object and zero recoverable backups. `retention-diff = 4` keeps a
few days of recent diffs + their hourly incrs; current state is always the latest
incr in the chain.

### Schedule (hourly incrementals)
`weekly full` (Sun 02:00) + `daily diff` (Mon..Sat 02:00) + `hourly incr` (:30,
offset off the :00 jobs to avoid lock collisions). With `archive_timeout = 60`,
WAL replay bridges the gap between backups, so effective RPO ≈ minutes.

### Layering after this change
| Layer | Tool | Gives | Restores |
|---|---|---|---|
| Whole-VM DR | PBS → R2 | crash-consistent VM, off-site | full VM rollback |
| Physical/WAL | **pgBackRest → R2** | current-state restore, validated incr, off-site | whole cluster |
| Logical | pg_dump | *kept during transition, then removed* | (interim) |

## Implementation sketch (R2 repo)
```nix
# hosts/database/configuration.nix

# KEEP services.postgresqlBackup { ... } through transition
# (remove only after first successful restore drill — see Rollout §7)

services.pgbackrest = {
  enable = true;
  repos.r2 = {                     # type=s3 → no default repo-host
    type = "s3";
    s3-bucket = "homelab-pgbackrest";
    s3-endpoint = "<accountid>.r2.cloudflarestorage.com";
    s3-region = "auto";
    s3-uri-style = "path";
    cipher-type = "aes-256-cbc";   # passphrase supplied out-of-band (below)
    retention-full = 2;            # → repo1-retention-full (prefix auto-added)
    retention-diff = 4;            # keep ~4 recent diffs + their hourly incrs
  };
  settings = {
    # REQUIRED: module only writes pgbackrest.conf; conf.d is NOT auto-read
    include-path = "/etc/pgbackrest/conf.d";
    compress-type = "zst";
    process-max = 2;
    archive-async = "y";           # don't block the DB if R2 is briefly unreachable
    spool-path = "/var/spool/pgbackrest";
    # Bound spool growth under sustained R2 outage (tune after first week)
    # archive-push-queue-max = "64MiB";  # optional; set once size is known
  };
  stanzas.default.jobs = {
    weekly = { schedule = "Sun 02:00";      type = "full"; };
    daily  = { schedule = "Mon..Sat 02:00"; type = "diff"; };
    hourly = { schedule = "*-*-* *:30:00";  type = "incr"; };  # :30 to avoid :00 collisions
  };
};
services.postgresql.settings.archive_timeout = "60";  # bound RPO on an idle DB
# archive-async spool dir (writable by both postgres and pgbackrest):
# postgres is a member of group pgbackrest (module)
systemd.tmpfiles.rules = [ "d /var/spool/pgbackrest 0750 pgbackrest pgbackrest -" ];
```

### Secrets via agenix (module blocks secrets in the store)
`cipher-pass`, `s3-key`, `s3-key-secret` are `disabledOption` by design. Set the
non-secret keys in Nix; drop the secrets into an include file under
`/etc/pgbackrest/conf.d/` (loaded because `include-path` is set above — covers
both the timer jobs and the postgres-run `archive_command`):
```nix
age.secrets.pgbackrest-secret = {
  file  = ../../secrets/pgbackrest-secret.age;   # see contents below
  path  = "/etc/pgbackrest/conf.d/secret.conf";
  owner = "pgbackrest";
  group = "pgbackrest";     # postgres is a member of pgbackrest (module adds it)
  mode  = "0640";
};
```
Secret file contents (INI). **`repo1-` is correct only while there is a single
repo** (module numbers repos by attrName order). Comment this if a second repo is
ever added:
```ini
[global]
repo1-cipher-pass=<openssl rand -base64 48>
repo1-s3-key=<R2 access key id>
repo1-s3-key-secret=<R2 secret access key>
```
**Off-host copy of `cipher-pass`:** store in a password manager. Lose the
passphrase → the encrypted R2 repo is unrecoverable junk. agenix on `database`
alone is not enough.

New secret → add the `database` host key as a recipient in `secrets/secrets.nix`
and `agenix -e pgbackrest-secret.age` **from inside `secrets/`** (see AGENTS.md
§6). Encryption is fixed at stanza-create — can't be added to an existing repo
without recreating the stanza.

## Monitoring & alerting (new — on `hosts/otel`)
The `otel` host runs Prometheus + Grafana but has **no Alertmanager and no alert
rules yet** — this backup work is the first thing worth paging on, so stand up
Alertmanager here. All signals below are **verified present in the live
Prometheus** (no new exporters needed), except the gold-signal textfile metric
we add on `database`:

- `pg_stat_archiver_failed_count`, `pg_stat_archiver_archived_count` (postgres
  exporter on `database`).
- `node_systemd_unit_state{instance="homelab-database", job="database-node"}` —
  already scrapes all units; will cover the new `pgbackrest-default-*.service`
  oneshots automatically.

### Add Alertmanager + rules + Caddy UI (`hosts/otel/configuration.nix`)

Full scope: Alertmanager service, Prometheus wiring, Caddy UI proxy, and phone
push via a thin webhook bridge (below).

```nix
services.prometheus.alertmanager = {
  enable = true;
  port = 9093;
  # Match prometheus pattern: handle_path strips prefix, so route-prefix=/
  webExternalUrl = "https://homelab-otel.dropbear-butterfly.ts.net/alertmanager";
  extraFlags = [ "--web.route-prefix=/" ];
  configuration = {
    route = {
      receiver = "homelab";
      group_by = ["alertname"];
      repeat_interval = "4h";
    };
    receivers = [{
      name = "homelab";
      # Local bridge on otel → HA notify (same phone path as axon/hamcp).
      # See "Notification path" below — AM cannot speak MCP.
      webhook_configs = [{
        url = "http://127.0.0.1:9095/alert";  # alertmanager-ha-bridge
        send_resolved = true;
      }];
    }];
  };
};
services.prometheus.alertmanagers = [
  { static_configs = [{ targets = ["localhost:9093"]; }]; }
];
services.prometheus.rules = [
  ''
    groups:
      - name: postgres-backup
        rules:
          - alert: PgBackRestJobFailed
            expr: node_systemd_unit_state{instance="homelab-database", name=~"pgbackrest-.*\\.service", state="failed"} == 1
            for: 5m
            labels: { severity: critical }
            annotations: { summary: "pgBackRest backup job {{ $labels.name }} failed" }
          - alert: PostgresWALArchiveFailing
            expr: increase(pg_stat_archiver_failed_count[15m]) > 0
            for: 15m
            labels: { severity: critical }
            annotations: { summary: "PostgreSQL WAL archiving to R2 is failing" }
          - alert: PostgresWALDiskFilling
            expr: node_filesystem_avail_bytes{instance="homelab-database", mountpoint="/"} / node_filesystem_size_bytes{instance="homelab-database", mountpoint="/"} < 0.25
            for: 10m
            labels: { severity: warning }
            annotations: { summary: "database / below 25% free (WAL/spool may be piling up)" }
          - alert: PgBackRestNoRecentBackup
            expr: |
              (
                time() - pgbackrest_last_backup_completion_timestamp_seconds > 90000
              ) or (
                absent(pgbackrest_last_backup_completion_timestamp_seconds) == 1
              )
            for: 30m
            labels: { severity: critical }
            annotations: { summary: "No pgBackRest backup completed in >25h (or metric missing)" }
  ''
];
```

Caddy (both Tailscale + `otel.homelab.local` vhosts — mirror `/prometheus*`):
```
handle_path /alertmanager* {
  reverse_proxy localhost:9093
}
```

Firewall: `tailscale0` is already `trustedInterfaces`, so AM UI works over
tailnet without opening 9093. Add `9093` to `allowedTCPPorts` only if LAN-without-
tailscale access is wanted. **Webhook is outbound otel→bridge(local)→HA; no
inbound 9093 required for paging.**

### Notification path: Alertmanager → bridge → HA notify (not raw axon MCP)

**Constraint:** Alertmanager only speaks HTTP webhooks. axon-gateway is an **MCP**
aggregator (`https://axon.homelab.local/mcp`); AM cannot call `hamcp_call_service`
directly.

**Same end path as hermes/axon today** (verified in
`hosts/hermes/skills/notifications/cron-result-delivery/SKILL.md`):

- HA service: `notify.mobile_app_iphone_von_amadeus`
- Via axon that is `hamcp_call_service(domain=notify, service=mobile_app_iphone_von_amadeus, …)`

**Implementation (on `otel`):** a tiny local webhook receiver
(`alertmanager-ha-bridge`) that:

1. Accepts Alertmanager's JSON POST on `127.0.0.1:9095/alert`.
2. Maps firing/resolved → title/message from `alerts[0].labels.alertname` /
   `annotations.summary` / `status`.
3. Calls Home Assistant REST:
   `POST https://<ha-host>/api/services/notify/mobile_app_iphone_von_amadeus`
   with a long-lived access token (agenix secret; HA already issues these —
   same trust model as hamcp's HA token).

Use `*.homelab.local` for the HA base URL (MagicDNS does not resolve between
homelab VMs — AGENTS.md). Exact HA hostname/IP is a deploy-time fill-in.

Keep the bridge loopback-only; no new public surface. Optional later: teach
axon a first-class HTTP notify route and point AM at that instead — out of
scope for v1.

### Gold-signal: PgBackRestNoRecentBackup (in scope)
The failure rules don't catch "the timer silently stopped." Add a node_exporter
**textfile collector** on `database`:
```nix
# hosts/database/configuration.nix — enable the textfile collector
services.prometheus.exporters.node = {
  enabledCollectors = [ "systemd" "processes" "textfile" ];
  extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile" ];
};
systemd.tmpfiles.rules = [ "d /var/lib/node_exporter/textfile 0755 pgbackrest pgbackrest -" ];
# 0755 (world-readable): node-exporter often runs DynamicUser, so it needs the dir
# + .prom files readable without a shared group. Metrics aren't secret.

systemd.services.pgbackrest-info-metric = {
  after = [ "network-online.target" ];
  serviceConfig = { Type = "oneshot"; User = "pgbackrest"; Group = "pgbackrest"; };
  path = [ pkgs.pgbackrest pkgs.jq ];
  script = ''
    ts=$(pgbackrest --stanza=default --output=json info \
      | jq '[.[0].backup[].timestamp.stop] | max // 0')
    tmp=/var/lib/node_exporter/textfile/pgbackrest.prom.$$
    {
      echo '# HELP pgbackrest_last_backup_completion_timestamp_seconds Unix time of most recent completed backup.'
      echo '# TYPE pgbackrest_last_backup_completion_timestamp_seconds gauge'
      echo "pgbackrest_last_backup_completion_timestamp_seconds $ts"
    } > "$tmp" && mv "$tmp" /var/lib/node_exporter/textfile/pgbackrest.prom
  '';
};
systemd.timers.pgbackrest-info-metric = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnCalendar = "*:00/15"; Persistent = true; };  # every 15 min
};
```

## Risks / gotchas (ordered by likelihood)
1. **`--allow-group-access` does NOT apply retroactively.** The module sets it in
   `initdbArgs`, but our cluster is already initialized → PGDATA is `0700`, the
   `pgbackrest` user can't read it → backup fails. **One-time host fix:** stop
   postgres, `chmod -R g+rX` the data dir + set it `0750`, restart (PG honors
   group access from the dir mode; accepts 0700 or 0750). Main operational risk.
   (`/var/lib/postgresql` is 0750 via tmpfiles, but the `18/` initdb subdir is
   0700.)
2. **Enabling `archive_mode` needs a full PostgreSQL restart** (not reload). The
   first deploy bounces postgres → brief outage for forgejo/buildbot/romm/
   hofvarpnir/etc. Do it in a quiet window.
3. **R2 reachability from `database`** — the archive_command runs on *every* WAL
   switch; if R2 is unreachable, WAL piles up in pg_wal and can fill the disk.
   Mitigated (`archive-async=y` + spool) so a brief R2 blip doesn't stall the DB,
   and by the `PostgresWALArchiveFailing` / `PostgresWALDiskFilling` alerts
   (threshold 25% free). A *sustained* R2 outage still fills the disk eventually —
   the alert is the backstop. Consider `archive-push-queue-max` after sizing.
4. **Missing `include-path`** — without it, agenix secrets in conf.d are ignored
   and check/backup fail with opaque S3/cipher errors. Set in `settings` (sketch).
5. **Btrfs NoCoW** — n/a for an S3 repo (no local repo dir). If we add Garage/
   local later, apply `+C` to that dir.
6. **Lost cipher-pass** — encrypted repo unrecoverable. Off-host password-manager
   copy required (above).

## Rollout steps
1. Create the R2 bucket (`homelab-pgbackrest`, versioning on, 14-day noncurrent
   lifecycle) + an R2 API token scoped to it. Put key/secret + cipher pass in the
   agenix secret; **also** store cipher-pass off-host.
2. Land the Nix change (**keep** `postgresqlBackup`; add pgbackrest + secret +
   textfile metric). `just fmt`, scoped eval
   `nix eval .#nixosConfigurations.database.config.system.build.toplevel.drvPath`.
3. Pre-deploy host fix: PGDATA group access (Risk #1). Confirm
   `sudo -u pgbackrest test -r <datadir>/global/pg_control`.
4. `just colmena-apply-host database` in a quiet window (expect a postgres
   restart).
5. Once: `sudo -u pgbackrest pgbackrest --stanza=default check`.
6. First full: `sudo -u pgbackrest pgbackrest --stanza=default --type=full backup`;
   then `pgbackrest --stanza=default info`.
7. **Rehearse a restore** to a scratch dir / throwaway VM (`pgbackrest restore`).
   A backup you haven't restored isn't a backup. **Only after this passes:**
   remove `services.postgresqlBackup` + its `/var/backup/postgresql` tmpfiles rule
   in a follow-up change.
8. **Alerting:** deploy Alertmanager + rules + Caddy UI + HA notify bridge on
   `otel` (`just colmena-apply-host otel`). Test by faking a failure (`systemctl
   start` a job with bad R2 creds, or `amtool`) and confirm the phone push lands.

## Verification
- `just fmt` + scoped per-host eval (full `nix flake check` OOMs — AGENTS.md).
- `pgbackrest --stanza=default check` succeeds; `info` shows full+diff with
  retention pruning after a week.
- `pg_stat_archiver`: `archived_count` climbing, `failed_count = 0`
  (Prometheus/Grafana). Alert on `failed_count > 0` and on pg_wal growth.
- Restore rehearsal succeeds; restored cluster starts clean.
- Phone push on firing + resolved; AM UI reachable at `/alertmanager`.

## Decisions locked in (plan is ready to implement)
- **Repo:** Cloudflare R2, single off-site (shared ZFS pool rules out any on-host
  target; R2 accepted as the single off-site).
- **Retention** 2 full / 4 diff; **schedule** weekly full + daily diff + hourly
  incr; goal = current-state restore, not deep PITR.
- `archive-async=y` + spool dir from the start; `include-path` for conf.d secrets.
- **Keep `services.postgresqlBackup` through transition; remove only after first
  restore drill.**
- **Alerting:** Alertmanager on `otel` + Caddy UI (`handle_path` + route-prefix)
  + rules including gold-signal `PgBackRestNoRecentBackup` (textfile + absent()).
- **Notify path:** AM webhook → local bridge on otel → HA REST
  `notify.mobile_app_iphone_von_amadeus` (same phone path as axon/hamcp; AM cannot
  call MCP directly).
- **R2 durability:** versioning + 14-day noncurrent lifecycle + bucket-scoped
  token + client-side aes-256-cbc. **No Object Lock** (breaks pgBackRest expire).
- Disk warning threshold **25%** free (was 15%).

## Remaining manual / external steps (not Nix)
- Create R2 bucket `homelab-pgbackrest` (versioning on, 14-day noncurrent
  lifecycle, token scoped to the bucket); put key/secret + cipher pass in the
  agenix secret **and** cipher-pass in a password manager.
- HA long-lived token for the otel bridge (agenix); confirm HA base URL as
  `*.homelab.local`.
- After first successful backup: **rehearse a restore**, then remove
  `services.postgresqlBackup`.
