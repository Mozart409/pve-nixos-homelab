# Woodpecker: move off SQLite, stop the VM ballooning away

> **Status 2026-08-06: fixes applied, not yet deployed or verified.** Memory is
> pinned, SQLite is hardened, build logs move out of the DB. **Postgres is
> deferred, not cancelled** — see the reasoning under that task. Two findings
> below were added after the original write-up: the connection-pool default and
> the missing `pve-node` metrics. Remaining work is deploy + verification.

Pipelines on `homelab-mcp-servers` are killed mid-run and reported as
**Canceled** in the UI, with no error in the step log. The build is fine; the
Woodpecker *server* loses track of the task. Every pipeline #11–#25 on
2026-08-05 ended `killed`, durations 57 s to 544 s.

This is not a CI-config problem — `.woodpecker/test.yaml` in that repo has
already been tuned twice (`max-jobs`/`cores`, then `http-connections`) to make
the workload small enough not to trip it. The fix belongs here.

## Evidence (pipeline #25, workflow 24, commit f2d784f)

Journald via Loki, `{job="woodpecker-server"}` / `{job="woodpecker-agent"}`,
host `homelab-woodpecker`, 2026-08-05 CEST:

| time | who | event |
|---|---|---|
| 21:37 | agent | `ci` step starts; `nix develop .#ci` substitutes ~800 paths from Attic |
| 21:39:38 | agent | `failed to extend workflow lease` — `rpc extend(): sql: no rows in result set` |
| 21:43 | agent | last log line written (t=320s), then silence |
| 21:44:55 | server | `queue: resubmitting expired task 24` / `queue: task expired` |
| 21:45:01 | server | `pull queue item: 24: not found in backup, dropping stale task` |
| 21:47:13 | agent | `could not destroy all containers` — the container was already gone |

Throughout, the server log is wall-to-wall `database is locked`.

## Root cause

Two compounding problems, both on this VM.

**1. Memory: the guest balloons down to ~1.2 GB.** `iac/main.tf` declares
`dedicated = 4096` / `floating = 1024`, and the comment at `main.tf:1099-1104`
budgets against the 4 GB figure. It is not there at runtime — `node_memory_MemTotal_bytes`
on `homelab-woodpecker` drifted 3033 → 1930 → 1785 → **1206 MB** across
2026-08-05 as the balloon reclaimed toward the floating minimum. At the moment
#25 died, `MemAvailable` was ~240 MB.

Meanwhile `hosts/woodpecker/configuration.nix:163-167` permits
`WOODPECKER_MAX_WORKFLOWS = 2` × `LIMIT_MEM = 1 GB` = 2 GB of step containers —
more than the whole guest currently has. The sizing comments in both files
assume memory that ballooning has already taken back.

**2. SQLite under that pressure.** `hosts/woodpecker/configuration.nix:110-111`
uses `sqlite3` with a bare path DSN — no WAL, no `busy_timeout`. When the box is
squeezed, writes serialise and start failing; the queue's task row goes missing,
the agent's lease-renewal RPC returns `sql: no rows in result set`, the fifo
queue expires the task, and a healthy running container is orphaned.

**2b. The connection pool made this much worse than memory alone would.** Added
2026-08-06. `WOODPECKER_DATABASE_MAX_CONNECTIONS` defaults to **100** —
confirmed against the running 3.16.0 binary, not just the docs:

```
--db-max-open-connections int   max connections xorm is allowed create (default: 100)
--db-max-connection-timeout     time an active connection is allowed to stay open (default: 3s)
```

A hundred pooled connections against one SQLite file, with no busy handler,
means concurrent writers get `SQLITE_BUSY` *immediately* rather than waiting.
That is a config default producing lock errors on its own — the memory pressure
widened the window, it did not create it. The original write-up read the lock
errors as purely downstream of ballooning; they were partly independent, which
is why the DSN fix belonged above "interim" all along.

Corollary: the DB is **1.2 MB** on disk. "Not a small-write workload" is right
about frequency and wrong about volume, and only frequency drives contention.

CPU is a distant third. The VM has **4 cores** (not 2, as an older comment in
the consuming repo claimed) and step containers are capped at 3 by
`WOODPECKER_BACKEND_DOCKER_LIMIT_CPU_QUOTA = "300000"`. load1 did hit 13.6, but
that is a symptom of memory-starved I/O, not the driver.

## Tasks

### Done 2026-08-06 (not yet deployed)

- [x] **Harden SQLite** — `hosts/woodpecker/configuration.nix`. Three changes,
  not the one the "interim" section proposed:
  - DSN → `?_journal_mode=WAL&_busy_timeout=10000&_txlock=immediate`. The
    param syntax is correct *because* 3.16 links `mattn/go-sqlite3`; it would
    be silently wrong under `modernc.org/sqlite`, which wants
    `?_pragma=journal_mode(WAL)`. Verified against upstream `go.mod`.
  - `WOODPECKER_DATABASE_MAX_CONNECTIONS = "1"` — see root cause 2b.
  - `WOODPECKER_LOG_STORE = "file"` + `WOODPECKER_LOG_STORE_FILE_PATH`, moving
    build output out of the DB entirely. Verified present in the 3.16 binary.
    The store `MkdirAll`s its own directory at 0700 under the existing
    StateDirectory, so no tmpfiles rule. **Existing pipelines' logs will read as
    empty afterwards** — the UI only reads the active store.
- [x] **Pin the memory** — `iac/main.tf`, `floating` 1024 → 4096. The host had
  15.2 GiB available, so the +1.4 GiB is affordable; the earlier worry about
  taking pages from elsewhere was overcautious for the short term. What it does
  do is make this VM a non-donor, which is now tracked in
  `todo/pve-gigabyte-memory-oversubscription.md`.
- [x] **Fix the `pve-node` scrape** — it was **down since 2026-08-05 ~14:00
  CEST** (`lookup pve-gigabyte.local: no such host`), i.e. there was no
  hypervisor memory data for the window this document diagnoses. Added
  `pve-gigabyte.homelab.local` A+PTR in `hosts/dns/configuration.nix` and
  retargeted `hosts/otel/configuration.nix:564`. This is why the doc's own
  instruction to "check pressure on pve-gigabyte first" could not be followed.

### To do
- [ ] **Deploy and verify.** `just colmena-apply-host woodpecker`, plus `dns`
  and `otel` for the scrape fix, plus `tofu apply` for the memory pin — note the
  memory change needs a VM **stop/start**, not a reboot, to take effect.
  Verification steps are below and are the whole point; none of the above is
  known to work yet.

### Deferred
- [ ] ~~**Move the server DB to Postgres.**~~ **Deferred 2026-08-06.** Reasoning:
  the `database` VM's storage is the *same* two-HDD `zfs_pool`, so this
  relocates the I/O rather than escaping it, while adding a cross-host
  dependency and network latency to a VM configured with 1536 MB. The DB is 1.2
  MB and, with `LOG_STORE = "file"`, is now metadata-only — the write profile
  that motivated the move is gone. Revisit if lock errors survive the changes
  above. If it happens, fix `log_statement = "all"` / `log_duration = true` on
  `hosts/database/configuration.nix:96-97` first: every Woodpecker query would
  otherwise be logged, on that same pool. Original reasoning preserved below.

  `hosts/woodpecker/configuration.nix:110-111`,
  `WOODPECKER_DATABASE_DRIVER = "postgres"` against the `database` VM. The
  comment there argues SQLite avoids "a cross-host dependency on the database
  VM" and that CI history is cheap to rebuild — both still true, but the
  dependency is now cheaper than the failure mode, which silently kills green
  pipelines. Note Woodpecker also stores **build logs** in this DB
  (`configuration.nix:235`), so it is not a small-write workload.
  - DSN goes in the agenix env file, not `environment` (world-readable store) —
    same treatment as `WOODPECKER_GRPC_SECRET`.
  - Migration: no supported dump/restore path between drivers. Simplest is to
    accept the history loss (stop server, switch driver, let it re-init) — CI
    history is explicitly declared disposable in the existing comment. Decide
    this consciously rather than discovering it.

  Since `MAX_WORKFLOWS` stays at 2 and the memory is now genuinely resident,
  the step budget (2 × 1 GB + ~700 MB system) fits 4 GB as originally intended.
  Cutting it to 1 was only needed under the "keep ballooning" branch.

### Lower impact
- [ ] **More cores, maybe.** `iac/main.tf:1094-1097`. Only after the memory and
  DB work — CPU is not what is failing, and adding cores without fixing memory
  makes the balloon situation worse, not better.
- [ ] **Consider splitting server and agent** onto separate VMs. Removes the
  class of failure entirely (an agent cannot starve a server it does not share a
  kernel with) at the cost of one more host to maintain. Probably not worth it
  if Postgres + pinned memory holds.

## Verification

- Reproduce first: restart a previously killed pipeline on
  `amadeus/homelab-mcp-servers` and confirm it still dies, so a green run after
  the change means something.
- During a run, watch `node_memory_MemTotal_bytes{instance="homelab-woodpecker"}`
  and `MemAvailable` — MemTotal should now be flat at the pinned value.
- Flat `MemTotal` is necessary but **not sufficient**: also confirm
  `node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes` stays near zero
  during a build. The guest has 4 GB of swap on `zfs_pool`, and swapping there is
  what turned a memory shortfall into an I/O collapse. If it swaps, the pin did
  not hold regardless of what MemTotal reports.
- `journalctl -u woodpecker-server` must be free of `database is locked` and
  `queue: task expired` for a full pipeline.
- Confirm the agent stops logging `failed to extend workflow lease`.
- A full `test` workflow (ci + cache-push + trivy) completing green is the
  acceptance test; it has not done so since #10.

## Related

- Consuming repo: `~/code/rust/homelab-mcp-servers/.woodpecker/test.yaml` — its
  `NIX_CONFIG` comments document this failure from the pipeline side and can be
  simplified once the server is stable.
- `todo/woodpecker-ci-deploy.md` — original build-out of this host.
- `todo/postgres-backup-pgbackrest.md` — if the DB moves to Postgres, CI history
  lands in that backup scope.
- `todo/pve-gigabyte-memory-oversubscription.md` — the host-level problem this
  VM was a symptom of. Pinning here shrank the balloon donor pool, so the next
  squeeze lands on a different guest.
