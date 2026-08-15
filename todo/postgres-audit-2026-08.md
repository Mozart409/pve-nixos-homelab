# Postgres audit via pgmcp — findings & plan (2026-08-15)

Read-only audit of all six `axon-gateway` Postgres backends (`pguptime`,
`pgappdb`, `pgterraform`, `pgforgejo`, `pgromm`, `pghofvarpnir`). Every finding
was gathered through the `mcp` role (read-only, `pg_read_all_data`) using the
pgmcp catalog tools plus bounded `run_query` SELECTs. No writes, no DDL, no
deploys.

**Nothing below has been actioned.** This document is the review artifact.

## Decisions taken (user review)

| Topic | Decision |
|---|---|
| `appuser` (DB still live, secret orphan in repo) | **Drop it.** Repo cleanup + live drop, with a dump first. |
| `forgejo` (confirmed empty leftover) | **Keep.** Migration to this host is planned later; backend and DB stay. |
| Redundant / unused indexes | **Research only.** Recorded here for verification later, not scheduled. |
| Everything else | Documented as a backlog; no action committed. |

---

## 1. Planned action: drop `appuser`

The hardening branch removed `appuser` from `ensureDatabases` and tore down its
pgmcp instance, but the **manual** parts never happened:

- `secrets/pg-mcp-appuser-url.age` still exists on disk and is still listed in
  `secrets/secrets.nix` (orphan — the hardening §0 cleanup was skipped).
- The live database and role still exist on the `database` host (~7.5 MB,
  scratch DB with no writer).

### 1a. Repo cleanup

```bash
git rm secrets/pg-mcp-appuser-url.age
# delete the "pg-mcp-appuser-url.age".publicKeys = [...] line from secrets/secrets.nix
rg -n 'appuser' secrets/secrets.nix   # must be empty after
```

No `just reencrypt` needed: removing a secret does not re-key the others.

### 1b. Live cluster — look before you delete

`appuser` was a scratch database whose only reader was its own (now-removed)
pgmcp instance, but that was inferred from the repo, not the live cluster:

```bash
ssh database.homelab.local 'sudo -u postgres psql -d appuser -c "\dt"'
ssh database.homelab.local 'sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('"'"'appuser'"'"'));"'
ssh database.homelab.local 'sudo -u postgres psql -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 20;"' # in appuser
```

If that shows real rows, **stop** — reconsider.

### 1c. Dump, then drop

```bash
ssh database.homelab.local 'sudo -u postgres pg_dump -Fc appuser > /var/backup/postgresql/appuser-final-$(date +%F).dump'
ssh database.homelab.local 'sudo -u postgres psql -c "DROP DATABASE appuser;"'
ssh database.homelab.local 'sudo -u postgres psql -c "DROP ROLE appuser;"'
```

If `DROP DATABASE` fails with *"is being accessed by other users"*, find the
client before forcing:

```bash
ssh database.homelab.local 'sudo -u postgres psql -c "SELECT pid, usename, application_name, client_addr, state FROM pg_stat_activity WHERE datname = '"'"'appuser'"'"';"'
```

The dump is the rollback — `appuser` is the only irreversible step in this plan.

---

## 2. Findings per database (research record)

Severity tags: [HIGH] / [MED] / [LOW]. All concrete fixes below require DBA
access on the host (`sudo -u postgres`) or an app-owner decision — the `mcp`
role is read-only by design.

### pguptime — uptime-forge TimescaleDB (containers host, 183 MB)

- Health clean; autovacuum live on hot chunks; stats window fresh.
- 8 schemas; user schema is one hypertable `public.uptime_events` (26 weekly
  chunks, ~6 months) + 2 continuous aggregates (`uptime_events_hourly`,
  `uptime_events_daily`) + `_sqlx_migrations`.
- **Indexes:** no duplicates. `public.uptime_events.idx_uptime_events_error_type`
  — partial `(endpoint_id, error_type, ts DESC) WHERE error_type IS NOT NULL` —
  has **0 scans in ~6 months** on every chunk including the active ones (whose
  `ts_idx`/pkey show 28k–86k scans in the same window). Unused write-path tax.
- **Retention:** no `drop_chunks` policy — raw rows live forever. Cost is low
  (compressed to ~1 MB/chunk), but the gap should be intentional.
- **Compression:** on (`segmentby endpoint_id`, `orderby ts DESC`, compress
  after 30 days, 12-hourly job healthy). ~113 MB sits in 4 pre-compression
  chunks; their `n_live_tup=0` stats are stale, not empty.
- **Schema smells [LOW]:** `status_code` / `latency_ms` nullable `integer` with
  no `CHECK` (negative latency would poison p95/p99 aggregates).
- **Ops [LOW]:** TSDB telemetry job (`policy_telemetry`, job 1) has failed
  42/189 times and its schedule is stale — this network is isolated; telemetry
  egress never succeeds.
- **Note:** full scans over the raw hypertable exceed the `mcp` role's 30 s
  statement timeout. Point ad-hoc queries at the continuous aggregates instead.

### pgappdb — appdb (database host, 7.7 MB)

- **Zero tables, zero objects.** 1 schema (`public`), empty. 21,099 commits and
  ~825k buffer hits show historical use; every relation is gone.
- No vacuum/bloat/index concerns — nothing to maintain.
- **Open question:** retired app, dropped tables, or self-provisioning at app
  bootstrap? If the latter, note PG15's `public` ACL only lets `postgres` create
  objects — an app that expects to create tables needs a DBA to pre-provision or
  grant `CREATE` to its role.
- **Decision:** left in place; re-audit once the intent is known.

### pgterraform — Terraform state (database host, 8 MB)

- 1 user table `terraform_remote_state.states` (1 live row, 65 KB JSON blob,
  custom/minimal pg backend), 1 sequence in `public`. XID age healthy.
- **[MED] Duplicate unique index:** `states_by_name` and `states_name_key` are
  byte-identical `UNIQUE btree (name)` — every state save pays double index
  maintenance.
- **[LOW]** `name` is the workspace key but nullable (NULL slips past the
  unique index). `data` is `text` not `bytea`; the official pg backend stores
  `created_at`/`updated_at`/`lock_id` — absent here (locking via
  `pg_advisory_lock` presumably).
- **Retention good:** one row per workspace, deleted on workspace delete.
- **[LOW, cosmetic]** sequence `global_states_id_seq` lives in `public`, its
  table in `terraform_remote_state`.

### pgforgejo — confirmed empty leftover (database host, 7.5 MB)

- **Verdict: empty scaffold.** 0 tables/views/sequences/functions; zero writes
  ever (`tup_inserted=0`); no `citext` (which real Forgejo requires) — migrations
  never ran here. All 7.5 MB is catalog baseline.
- The 21k `xact_commit` + a parked idle backend are the pgmcp monitor ping, not
  app traffic.
- **Decision:** KEPT — a real Forgejo migration onto this host is planned. The
  pgmcp instance and axon-gateway `pgforgejo` backend stay. Re-check after the
  migration lands whether this DB actually becomes the target (or whether the
  forgejo-host DB is moved here and this scaffold gets replaced).

### pgromm — RomM (database host, 10 MB, freshly provisioned)

- 26 tables + 3 views, alembic at current upstream. Essentially no data yet
  (`roms`=1, `saves`=2, `users`=1). All `last_vacuum/analyze` NULL — stats
  stale until real data lands.
- **Schema:** no missing PKs. **6 unindexed FKs [MED]**:
  `collections.user_id`, `firmware.platform_id`, `play_sessions.sync_session_id`,
  `screenshots.rom_id`, `screenshots.user_id`, `smart_collections.user_id` —
  the classic join/deep-delete foot-gun once the library grows.
- **Indexes:** no true duplicates (`idx_roms_name` btree + `idx_roms_name_trgm`
  GIN are both used — `=`/`ORDER BY` vs `ILIKE`). **20 indexes on `roms`**
  including the 9-column `idx_roms_sibling_cover` and 11 single-column
  provider-id indexes — latent write/space tax, harmless at 10 MB.
- **[LOW]** `rom_files.last_modified` is `double precision` (epoch float) vs
  `timestamptz` everywhere else — an upstream schema decision, likely leave.
- **Action candidates:** index the 6 FK columns (single `CREATE INDEX` each,
  `CONCURRENTLY`); `VACUUM ANALYZE` after the first real sync. Both DBA-gated.

### pghofvarpnir — hofvarpnir (jellyfin host, 18 MB)

- 11 tables (sqlx-managed), largest `activity_events` 6.7 MB / ~19k rows.
- **[MED] Stale stats:** `activity_events` `n_live_tup=705` vs 19,144 real rows,
  `last_analyze`/`last_autovacuum` NULL — planner estimates ~27× off.
- **[MED→LOW] Unbounded log:** `activity_events` is an append-only event log with
  no retention; it is the largest table and grows forever.
- **Duplicate indexes [LOW]:** `users_email_key` UNIQUE + `idx_users_email`;
  `issuer_subject_key` UNIQUE + `idx_oidc_identities_lookup` — identical column
  lists. **Prefix-redundant [LOW]:** `idx_api_keys_user_id` (covered by
  `idx_api_keys_user_id_name`), `idx_source_videos_source_id` (covered by the
  PK's leftmost column).
- **Zero-scan indexes [LOW, indicative]:** `idx_videos_downloaded_at` (partial),
  `idx_sources_enabled`, `idx_sources_last_indexed_at`, `idx_sources_profile_id`
  — likely dead after the workflow moved to the `cleaned` state; verify with the
  app owner before dropping.
- **Unindexed FKs [LOW]:** `activity_events.video_id` / `.profile_id` — both
  nullable on an append-only log, minor.
- No missing PKs; type hygiene good (`timestamptz`, enums, no JSONB).

---

## 3. Verification backlog (deferred — research for later)

Each item has the verification needed before acting. Do **not** schedule these
without checking the live stats window (all `idx_scan=0` findings were partly
indicative — the `database` host's stats are young).

### Redundant / unused index drops

| DB | Index | Why it looks droppable | Verify before dropping |
|---|---|---|---|
| pgterraform | `states_by_name` or `states_name_key` | byte-identical UNIQUE on `name` | `SELECT pg_get_indexdef(...)` both — identical |
| pghofvarpnir | `idx_users_email` | dup of `users_email_key` | `idx_scan` on both; app doesn't rely on the index name |
| pghofvarpnir | `idx_oidc_identities_lookup` | dup of `issuer_subject_key` | same |
| pghofvarpnir | `idx_api_keys_user_id` | covered by `idx_api_keys_user_id_name` | `idx_scan`; queries never use it alone |
| pghofvarpnir | `idx_source_videos_source_id` | covered by PK leftmost column | `idx_scan` |
| pghofvarpnir | `idx_videos_downloaded_at`, `idx_sources_*` | 0 scans over months | app owner confirms workflow no longer filters on these |
| pguptime | `idx_uptime_events_error_type` | 0 scans in ~6 months incl. hot chunks | app owner confirms no error_type filter; monitor dashboards |
| pgromm | `idx_roms_sibling_cover`, 11 provider-id indexes | only needed during rare sibling-scan | re-benchmark once the library is populated |

### Statistics hygiene

- `pghofvarpnir`: `ANALYZE public.activity_events;` (estimates 27× off).
- `pgromm`: `VACUUM ANALYZE` after the first real scan sync.
- `pguptime`: `ANALYZE` post-compression chunks (pre-compression stats read 0).

### Retention decisions

- `pghofvarpnir`: retention/prune for `activity_events` (cron prune or monthly
  partitioning).
- `pguptime`: decide whether raw rows need a `drop_chunks` policy. Cheap as-is
  (compressed), but the "keep everything forever" default should be explicit.

### Schema smells (lowest priority)

- `pgterraform`: `ALTER TABLE ... ALTER COLUMN name SET NOT NULL;` — sequence
  `global_states_id_seq` → `terraform_remote_state` (cosmetic).
- `pguptime`: `CHECK (latency_ms >= 0)`, optionally range-check `status_code`.
- `pgromm`: `rom_files.last_modified` epoch-float vs `timestamptz` — likely
  leave (upstream schema).

### Ops

- `pguptime`: `timescaledb.telemetry_level = off` — telemetry job 1 keeps
  failing against an isolated network.
- `mcp` role: decide whether the 30 s `statement_timeout` is worth raising.
  Dashboard queries should target the continuous aggregates, not the raw
  hypertable, so the bound is arguably working as intended.

---

## 4. Recurring audit

This was a one-shot. The catalog queries in section 2 are re-runnable verbatim
through pgmcp; consider a quarterly pass over the six backends (or a
Prometheus/alert rule for stale `last_analyze` / unindexed FK growth).

---

## 5. Mirror check

Per AGENTS.md §3.6 — check `github` vs `origin` after this lands.
