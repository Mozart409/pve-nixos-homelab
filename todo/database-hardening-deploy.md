# Database hardening — deploy playbook

Post-deployment runbook for branch `feat/database-hardening`
(8 commits, `hosts/database/configuration.nix` plus the `appuser` teardown
across `mcp_vm`, `dns` and `containers`).

**Nothing below has been done yet.** The branch is pushed to Forgejo and
evaluates clean, but it was developed on a workstation that cannot deploy —
every `nix eval` passed, no host has been built or applied.

What the branch changes, in one paragraph: PostgreSQL on the `database` host
gains cluster-wide session timeouts with per-role exemptions, statement logging
drops from *every* statement to DDL-plus-slow-only, the backup list is derived
from `ensureDatabases` (which fixes `attic` never having been dumped and stops
the nightly dump of the empty `forgejo` database), the seven role-password
oneshots collapse into one builder, the dead pgbouncer firewall port goes, and
the unused `appuser` database is removed along with its pgmcp instance.

---

## 0. Before you deploy — one cleanup this branch could not make

`secrets/` is unreadable to the agent that wrote this branch, so one orphan was
left in place. It is **not blocking** — nothing references it any more, the
hosts build without it — but it should be tidied:

```bash
rg -n 'pg-mcp-appuser-url' secrets/secrets.nix   # one line, in the keep-sorted block
```

Delete that line and the file:

```bash
git rm secrets/pg-mcp-appuser-url.age
```

Confirmed de-referenced already — `age.secrets` on the mcp host no longer
mentions it:

```bash
nix eval --json '.#nixosConfigurations.mcp.config.age.secrets' --apply 's: builtins.attrNames s'
# pg-mcp-appuser-url must NOT appear
```

No `just reencrypt` needed: removing a secret does not re-key the others.

---

## 1. Build gate

`just nixos-check` does **not** gate the colmena deploy (AGENTS.md §3). Use the
hive build, which is the only thing that exercises what `colmena apply` builds:

```bash
just colmena-build-host database
just colmena-build-host mcp
just colmena-build-host dns
just colmena-build-host containers
```

---

## 2. Deploy order

Order matters for the `appuser` teardown: remove the *consumer* before the
thing it consumes, so nothing is left pointing at a vhost that has gone away.

```bash
just colmena-apply-host containers   # drops the pgappuser backend from axon-gateway
just colmena-apply-host mcp          # removes the pgmcp-appuser-server unit + its vhost
just colmena-apply-host dns          # removes the pg-appuser-mcp A + PTR records
just colmena-apply-host database     # the actual hardening; RESTARTS POSTGRES
```

**PostgreSQL will restart, not reload.** The NixOS module puts the generated
`postgresql.conf` in `restartTriggers`, so *any* `services.postgresql.settings`
change bounces the server regardless of whether the individual GUCs are
SIGHUP-able. Every consumer drops its connections: atticd (`cache`), romm and
uptime (`containers`), hofvarpnir (`jellyfin`), terraform, the pgmcp servers
(`mcp`), pgAdmin, and pgbouncer's pools. **Pick a quiet window.**

`atticd` is the one to watch — it runs sea-orm migrations on connect:

```bash
ssh cache.homelab.local 'systemctl status atticd'
```

### Restart that `colmena apply` does NOT do for you

Per AGENTS.md §3.5 — this branch edits axon-gateway's `config.toml` backends,
so the restart is **required**, not optional:

```bash
ssh containers.homelab.local 'sudo systemctl restart podman-axon-gateway'
```

If hermes has parked the axon-gateway MCP as a result, bounce it too:

```bash
ssh hermes.homelab.local 'sudo systemctl restart hermes-agent'
```

---

## 3. Verify the globals — and verify what is deliberately NOT global

```bash
sudo -u postgres psql -c "SHOW statement_timeout; SHOW lock_timeout; SHOW transaction_timeout; SHOW idle_in_transaction_session_timeout; SHOW idle_session_timeout; SHOW tcp_keepalives_idle;"
```

Expected: `5min`, `1min`, `15min`, `2min`, `8h`, `60`.

```bash
sudo -u postgres psql -c "SHOW log_statement; SHOW log_duration; SHOW log_min_duration_statement;"
```

Expected: `ddl`, `off`, `1s`. **`log_duration` must be `off`** — left on it
re-logs a duration line for every statement and defeats the threshold entirely.

---

## 4. Verify the per-role exemptions — this is the real proof

The globals are written by Nix into `postgresql.conf`, so they are hard to get
wrong. The per-role settings are applied by `ALTER ROLE` inside the
`postgresql-<role>-password` oneshots, which only run **if activation restarted
those units**. That is the step most likely to silently not happen.

```bash
sudo -u postgres psql -c "SELECT r.rolname, s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole ORDER BY 1;"
```

Expected:

| Role | setconfig |
|---|---|
| `attic`, `forgejo`, `romm`, `hofvarpnir` | `statement_timeout=0`, `lock_timeout=0`, `transaction_timeout=0` |
| `terraform` | the three above **+** `idle_session_timeout=0` |
| `postgres` | the three above **+** `idle_session_timeout=0`, `idle_in_transaction_session_timeout=0` |
| `mcp` | `default_transaction_read_only=on`, `statement_timeout=30s`, `lock_timeout=5s`, `idle_in_transaction_session_timeout=30s`, `transaction_timeout=1min`, `idle_session_timeout=10min` |

If a role is missing its row, the oneshot did not re-run. Force it:

```bash
sudo systemctl restart postgresql-attic-password postgresql-mcp-password \
  postgresql-terraform-password postgresql-forgejo-password \
  postgresql-romm-password postgresql-hofvarpnir-password \
  postgresql-superuser-password
```

Then confirm all seven are healthy:

```bash
systemctl list-units 'postgresql-*-password.service'   # all active (exited)
```

**Why the exemptions exist, so nobody "tidies" them away later:** every service
role runs its own schema migrations (sea-orm for atticd, xorm for forgejo,
alembic for romm/hofvarpnir), and on this 2-HDD ~78 IOPS pool a migration
legitimately outruns a 5-minute statement bound, takes ACCESS EXCLUSIVE locks
that outrun a 1-minute lock bound, and wraps it all in one transaction. Bounding
any of those turns a slow deploy into a service that will not start. `postgres`
is exempt because it runs the nightly `pg_dump` of five databases and the
prometheus exporter.

If some service starts failing with `canceling statement due to statement
timeout`, **the fix is an exemption on its role, not raising the global.**

---

## 5. Verify the backup fix — `attic` is the whole point

`attic` had never been dumped, from the day it was added, despite atticd
refusing to start without it.

```bash
sudo -u postgres psql -c "SELECT 1"   # sanity
systemctl list-units 'postgresqlBackup-*'
```

Expected units: `appdb`, `terraform`, `romm`, `hofvarpnir`, `attic`.
**No `forgejo`** (empty leftover — the real one is dumped on the forgejo host at
02:30) and **no `appuser`** (dropped, see §6).

Force the new one rather than waiting for 03:00:

```bash
sudo systemctl start postgresqlBackup-attic
ls -lh /var/backup/postgresql/
```

`attic.sql.zstd` must be **non-trivial in size**. A few hundred bytes means
atticd is not actually using this database, which is a separate incident worth
opening.

Remove the orphaned forgejo dumps — dropping it from the list does not delete
the files. Confirm the real backup exists first:

```bash
ssh forgejo.homelab.local 'ls -lh /var/backup/postgresql/'
sudo rm -f /var/backup/postgresql/forgejo.sql.zstd /var/backup/postgresql/forgejo.prev.sql.zstd
```

Note there are now five concurrent `pg_dump`s at 03:00 (was five, briefly six).
On 78 IOPS that is real contention, but these databases are small and
`todo/postgres-backup-pgbackrest.md` replaces this whole layer, so no
`RandomizedDelaySec` was added.

---

## 6. Drop the `appuser` database and role — MANUAL AND IRREVERSIBLE

**`ensureDatabases` only ever creates.** Removing `appuser` from the Nix config
stops managing it; it does **not** drop anything. The live database and role
survive the deploy untouched until you run the SQL below.

Look before you delete. `appuser` was believed to be a scratch database whose
only reader was its own pgmcp instance, but that was inferred from grepping the
repo, not from the live cluster:

```bash
sudo -u postgres psql -d appuser -c "\dt"
sudo -u postgres psql -d appuser -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 20;"
sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('appuser'));"
```

If that shows real rows, **stop** and reconsider — the config change is
harmless on its own and can sit indefinitely without dropping anything.

Take a dump first regardless. It is the last one that will ever exist:

```bash
sudo -u postgres pg_dump -Fc appuser > /var/backup/postgresql/appuser-final-$(date +%F).dump
ls -lh /var/backup/postgresql/appuser-final-*.dump
```

Then, and only then:

```bash
sudo -u postgres psql -c "DROP DATABASE appuser;"
sudo -u postgres psql -c "DROP ROLE appuser;"
```

If `DROP DATABASE` fails with *"is being accessed by other users"*, something
still connects to it — find out what before forcing:

```bash
sudo -u postgres psql -c "SELECT pid, usename, application_name, client_addr, state FROM pg_stat_activity WHERE datname = 'appuser';"
```

Confirm the pgmcp side is gone too:

```bash
ssh mcp.homelab.local 'systemctl list-units "pgmcp-*"'      # no pgmcp-appuser-server
curl -sk -o /dev/null -w '%{http_code}\n' https://pg-appuser-mcp.homelab.local/mcp   # expect 000
curl -sk -o /dev/null -w '%{http_code}\n' https://pg-appdb-mcp.homelab.local/mcp     # expect 406 (healthy)
```

`406` is healthy for an MCP endpoint reached without an `Accept` header; `000`
means gone, which is what you want for appuser and *not* what you want for the
others.

---

## 7. Confirm the logging actually got quieter

The whole justification for the logging change is IO on a 78 IOPS pool, so
measure it rather than assuming:

```bash
sudo journalctl -u postgresql --since '10 min ago' | wc -l
```

Compare against a pre-deploy sample if you took one. DDL and >1s statements
should still appear; the prometheus exporter's `pg_stat_*` polling every 15s
should no longer be in there at all.

---

## 8. Smoke-test the mcp bound

From the mcp host, push something deliberately slow through pgmcp and confirm it
is refused at ~30s rather than hanging:

```bash
sudo -u postgres psql -c "SET ROLE mcp; SET statement_timeout = '30s'; SELECT pg_sleep(60);"
# expect: ERROR: canceling statement due to statement timeout
```

Also confirm the read-only guard still holds:

```bash
sudo -u postgres psql -c "SET ROLE mcp; CREATE TABLE nope(i int);"
# expect: ERROR: cannot execute CREATE TABLE in a read-only transaction
```

---

## 9. Rollback

The config is one `colmena apply` away from reverting, but **two things do not
roll back on their own**:

1. **`ALTER ROLE ... SET` does not converge.** It lives in
   `pg_db_role_setting`. Reverting the Nix change leaves every per-role timeout
   in place on the live cluster. Backing them out is manual:
   ```bash
   sudo -u postgres psql -c "ALTER ROLE mcp RESET statement_timeout;"   # etc, per role per GUC
   ```
   Or wholesale for one role: `ALTER ROLE mcp RESET ALL;` — but note that also
   clears `default_transaction_read_only`, which you want to keep.
2. **A dropped database is gone.** §6 is the only irreversible step here; the
   dump it tells you to take is the rollback.

---

## 10. Open question this branch deliberately did not answer

**Is pgbouncer used by anything?** It binds `127.0.0.1:6432` and every consumer
found in the repo connects to `192.168.2.134:5432` directly. The firewall port
was removed (it advertised a port that always refused), but the service is still
running. Deciding needs live evidence:

```bash
sudo -u postgres psql -c "SELECT DISTINCT application_name, client_addr FROM pg_stat_activity;"
sudo journalctl -u pgbouncer --since '30 days ago' | head
```

If nothing has ever used it, a follow-up branch should delete
`services.pgbouncer` and `systemd.services.pgbouncer-userlist` — the latter
writes the postgres superuser's SCRAM hash to
`/var/lib/pgbouncer/userlist.txt` for nothing.

---

## 11. Mirror check

Per AGENTS.md §3.6. Note the `github` remote is **not currently configured** in
this clone (`git remote -v` shows only `origin`), so add it before this means
anything:

```bash
git fetch github
git log --oneline github/main..main
```
