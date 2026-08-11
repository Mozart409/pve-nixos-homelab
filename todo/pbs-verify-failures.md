# PBS verification has failed every week since at least April

The weekly `sat 01:15` verify job on `r2-store` has ended in
`TASK ERROR: verification failed` on **every run we have logs for**, going back
to 2026-04-30. Each run names one or two snapshots whose chunks "could not be
verified". Nobody noticed, because the notifications are not landing.

**This is not the immich problem.** The immich backup is *slow*
([`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md)) and that is a
throughput issue with a known fix. This is a *correctness* issue on a different
axis: it hits VMs and containers alike, rotates between guests, and migrating
immich to a VM will not touch it.

**The failing snapshots are ~24 hours old when they fail.** The nightly job runs
at 03:00 with `keep-last=1`; verify runs Saturday 01:15 against whatever was
written the night before. Chunks that fail are therefore **freshly written**, not
aged. Whatever this is, it happens at write/upload time or at read-back time —
it is not bit rot on the HDDs.

## The record

| Verify run | Snapshots that failed | Age at verify |
| --- | --- | --- |
| 2026-04-30 | (log not yet pulled) | — |
| 2026-06-20 | `vm/4327` (unifi) @ 06-19 | ~24 h |
| 2026-07-11 | `ct/104` (immich) @ 07-10 | ~24 h |
| 2026-07-18 | `vm/4327` (unifi) @ 07-17 | ~24 h |
| 2026-07-25 | `ct/104` @ 07-24 **and** `vm/4323` (database) @ 07-24 | ~24 h |
| 2026-08-01 | `ct/104` @ 07-28 | 4 d |

Four distinct guests affected: `vm/4327`, `vm/4323`, `ct/104`. Both backup
methods (block-level `.fidx` and file-level `.pxar.didx`). No guest is spared and
none fails consistently — the distribution looks **random**, which is the single
most important clue.

**Live facts (verified 2026-08-01):**

| Fact | Value |
| --- | --- |
| Datastore | `r2-store`, **`backend type=s3`** — Cloudflare R2, bucket `pve-backups` |
| Local cache | `/mnt/datastore/r2-cache` on `vm-180-disk-0` (222 G logical, on the 2-HDD `zfs_pool`) |
| GC last run | 2026-08-01 05:19, `OK`, 3 m 57 s, removed 21,297 chunks / 48.1 GB |
| GC `still-bad` / `removed-bad` | **`0` / `0`** — PBS is recording **no bad chunks at all** |
| GC cache hits / misses | 23,586 / 33,064 |
| Referenced vs stored | `index-data-bytes` 227.4 GB vs `disk-bytes` 98.1 GB (≈2.3× dedup) |
| PBS version | **Installed `4.1.1-1`, Candidate `4.2.4-1`** (`apt policy`, 2026-08-01). Last dpkg upgrade **2026-01-12**. Installed and running agree — there is **no** restart problem; PBS is simply **seven months and four releases out of date** (4.2.1/4.2.2/4.2.3/4.2.4 all missed). Beware: `proxmox-backup-manager version` prints `<pkg> <AVAILABLE> running version: <RUNNING>`, which reads like an unloaded upgrade and has now misled two investigations. |
| Backend detail | `type=s3,client=cloudflare-r2,bucket=pve-backups`, path `/mnt/datastore/r2-cache` |
| `.bad` chunks on disk | **0** — but chunks live in R2, not the local cache, and PBS's `.bad` renaming was built for the filesystem backend, so this is suggestive, not conclusive |
| Verify job | `v-b4b3326e-0c8d`, schedule `sat 01:15` → **`sat 06:15` since 2026-08-09** (see [Follow-up](#follow-up-2026-08-09--verify-was-colliding-with-the-backup-chain)) |
| Notifications | Every failing run logs `queued notification (id=…)`. None have been seen. |

## Status — RESOLVED 2026-08-01

**Fix applied and confirmed.** Verify job set to `read-threads=1` /
`verify-threads=4`; a full `--ignore-verified false` pass at those settings
returned **`TASK OK`, all 5 groups, 0 errors, 59 minutes** — the first genuinely
clean verify on `r2-store` since at least April. All three snapshots that
"failed" at 16 threads passed, `vm/4327` included.

| Group | Chunk data read | Errors |
| --- | --- | --- |
| `ct/102` | 1.1 GB | 0 |
| `ct/104` | 65 GB | 0 |
| `vm/4323` | 10.4 GB | 0 |
| `vm/4327` | 10.8 GB | 0 |
| `vm/4341` | 8.3 GB | 0 |

Beware the hollow green: a `Run Now` with **Skip Verified** on completed in
**1 second** with `TASK OK`, having skipped every group as "recently verified" —
*including the three that had just failed*. Only `--ignore-verified false`
proves anything.

### Also done 2026-08-01

- **Retention raised off `keep-last=1`** — nightly job now `keep-daily=7` +
  `keep-weekly=4`; immich job `keep-last=2` → `4`. One restore point was the
  single largest real risk in this whole investigation.
- **Notification delivery root-caused.** Postfix queue held deferred mail to
  `amadeus@mozart409.com` failing with
  `Name service error for name=mozart409.com type=MX: Host not found`. PBS was
  generating notifications correctly for three months; **DNS MX resolution on the
  PBS host** ate every one. `relayhost` empty, no `root:` alias. Queue flushed
  (`postsuper -d ALL`, 5 messages).
- **Rebuilt on a webhook — WORKING end to end.** Target `ha-push` →
  `http://192.168.2.208:8123/api/webhook/pbs-notify`, `default-matcher`
  retargeted to it, `mail-to-root` disabled. HA automation routes by severity:
  everything to the notification panel, `error`/`warning` also push to the phone.
- **Upgraded PBS 4.1.1 → 4.2.4** — installed and running now agree.

### ⚠️ The webhook JSON-escaping trap (cost an hour)

The obvious body template is **broken** and fails *silently*:

```
{"title": "{{ title }}", "message": "{{ message }}", "severity": "{{ severity }}"}
```

PBS messages contain **raw newlines** — even its own test message ends with one —
and a literal control character inside a JSON string is invalid JSON. HA accepts
the POST (`200 OK` at the HTTP layer), fails to parse the body, and **never fires
the trigger**. Nothing is logged on either side. `curl` with a hand-written
payload works fine, which makes it look like a PBS dispatcher bug; it is not.

**Use the `json` helper — no quotes around the values, it supplies them:**

```
{"title": {{ json title }}, "message": {{ json message }}, "severity": {{ json severity }}}
```

This matters far beyond the Test button: a verify failure lists each failed
snapshot on its own line, so **every alert worth having would have vanished**.

Diagnosis that cracked it: `timeout 30 tcpdump -i any -n -A 'host <ha-ip> and port 8123'`
while pressing Test — the raw request body is visible immediately. Reach for that
before assuming a dispatcher bug; both PBS's logs and HA's were silent.

### Follow-up 2026-08-09 — verify was colliding with the backup chain

The `read-threads=1` fix traded speed for correctness, which was the right trade
— but it made the verify job long enough to overlap the nightly backups, and
nobody re-checked the schedule afterwards. At `sat 01:15` a ~4h48m run covers
**03:00–03:50**, which is exactly the nightly chain (`ct/102` → `vm/4323` →
`vm/4327` → `vm/4341`). Both contend for the same R2 connection *and* the same
2-HDD `zfs_pool` underneath the local cache.

It showed up plainly in the task history:

| | 2026-08-08 (verify running) | 2026-08-09 (uncontended) |
| --- | --- | --- |
| `vm/4327` | 18m 39s ← 9-day max | 8m 21s |
| `vm/4341` | 11m 47s ← 9-day max | 3m 31s |
| `vm/4323` | 13m 20s | 5m 58s |
| `ct/102` | 5m 04s | 10m 07s |
| **chain total** | **~49 min** | **~28 min** |

The verify paid for it too: **4h 48m** scheduled, versus **59 min** for the
manual uncontended full pass on 08-01 over the same data.

**Moved to `sat 06:15`** — clear of the 03:00 chain and the 05:15 GC. Note the
day of week is irrelevant: the backup chain runs at 03:00 *every* day, so this
is a time-of-day fix. Expect the 2026-08-15 run to land near an hour; if it is
still ~5 h, the contention theory is wrong and something else is throttling R2.

Everything else in the job dialog was already correct and should stay:
`read-threads=1` (the fix itself — do not retest casually), `verify-threads=4`,
Skip Verified **on**, Re-Verify After **30 days**. 30 is right because retention
is `keep-daily=7` + `keep-weekly=4`, so nothing lives much past ~28 days and each
snapshot gets its one verification while new. Skip Verified must still be turned
**off** for any manual re-test after a failure — that is the hollow green above,
and it is a `Run Now` concern, not a steady-state one.

### Still open

- [ ] **Do one real restore.** Carried up from
      [below](#do-this-now-regardless-of-hypothesis) because it is now the only
      item here that protects against data loss. Nothing in this document proves
      a backup is *restorable* — verification proves chunks are readable, and
      this datastore has already lied in both directions (false failures at 16
      threads, a hollow `TASK OK` in 1 second with Skip Verified). Restore
      `ct/102` (pocketid, ~1.9 GB, the cheapest) to a scratch guest and confirm
      it boots.
- [ ] **A second, HA-independent target.** `ha-push` is the only channel and it
      dies exactly when the homelab does — as it did today. PBS's native **SMTP**
      endpoint needs only an A record and credentials, so it dodges both the MX
      bug and the HA dependency.
- [x] **`dig MX mozart409.com`** — resolves fine (Proton MX, 300s TTL). Not
      MX-specific: the failures were **intermittent**, and PBS's sole resolver is
      **`100.100.100.100`** (Tailscale MagicDNS). Since PBS reaches R2 through
      that same resolver, this is a latent single point of failure *under the
      backups*. Split out into
      [`dns-tailscale-spof.md`](./dns-tailscale-spof.md).
- [ ] **Post-reboot fleet check** — `pgadmin.service` blocked the `database` VM's
      boot for ~3 min and Caddy failed 5× before recovering. Probably cold-start
      races; confirm they are not permanent.

---

## Original diagnosis (2026-08-01)

**Root cause: the verify job's `read-threads = 16`.** PBS's default is **1**.
Against an S3 backend, 16 concurrent chunk reads produce a small but steady rate
of failed reads, which PBS reports as `chunks could not be verified` —
indistinguishable in the task log from real corruption. **The backups were never
corrupt.**

### The controlled experiment

Two full-datastore verifies, one hour apart, same 4.1.1 code, same snapshots,
**only the thread count changed**. Verification is read-only, so the data
provably did not change between runs.

| Group | Chunk data read | `--read-threads 1` (09:31) | `--read-threads 16` (10:26) |
| --- | --- | --- | --- |
| `ct/102` | 1.1 GB | 0 errors | 0 errors |
| `ct/104` | 65 GB | **0 errors** | **5 errors** |
| `vm/4323` | 10.4 GB | **0 errors** | **1 error** |
| `vm/4327` | 10.8 GB | (run aborted before) | **1 error** |
| `vm/4341` | 8.3 GB | (not reached) | 0 errors |

**Errors scale with bytes read** — 5 on 65 GB, 1 each on ~10 GB, 0 on the two
smallest groups. That is a constant per-request failure probability of roughly
**1 in 3,000 chunk reads**, not damage to particular snapshots. It explains the
entire historical record: a different random guest every week, always 1–3 errors,
never the same snapshot twice, and no chunk ever proven bad
(`still-bad: 0` was telling the truth all along).

**The concurrency is not even buying much:** ~60 MB/s at 16 threads vs ~28 MB/s
at 1. A 2.1× speedup for a 3,000× worse error rate.

### The mechanism, confirmed in the journal

`journalctl -u proxmox-backup-proxy` for the 16-thread run — **exactly 7 lines,
matching the 5 + 1 + 1 reported errors**, and every one identical:

```
Aug 01 10:34:38 pbs proxmox-backup-proxy[454823]: can't verify chunk, load failed - error reading a body from connection
```

**`error reading a body from connection` is an HTTP body truncated mid-transfer,
not a digest mismatch** — and there is not a single digest-mismatch line in the
run. The chunk was never read, so it could not be checked, and PBS scores that
the same as corrupt.

Full chain: 16 parallel GETs → R2 drops some response bodies mid-read → PBS
treats unreadable as unverifiable → snapshot marked failed, **with no retry**.
That last part is the actual defect and it is upstream's.

Job identity for reference: `v-b4b3326e-0c8d`, `sat 01:15`, Skip Verified on,
Re-Verify After 30 days, **Read Threads 16 / Verify Threads 16**.

### Consequences

- **Three months of weekly "verification failed" alerts were false.** No data was
  ever lost. The `ct/104` snapshot flagged as unrestorable is fine.
- The corresponding warnings in
  [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md) about having no
  restorable immich backup are **withdrawn** — see that file.
- What remains genuinely broken is **notification delivery** (Phase 2), which is
  what let a misleading-but-loud signal go unexamined for three months.

---

## Two hypotheses — RESOLVED: H1, in its concurrency form

*Kept for the reasoning trail. **H1 confirmed, H2 ruled out** by the experiment
above.*

### H1 — Transient R2 read failures during verify (backups are actually fine)

`chunks could not be verified` covers **both** "the bytes do not match the
digest" *and* "the chunk could not be read at all". On an S3-backed datastore,
verification pulls chunks from R2. A handful of GETs timing out or 5xx-ing in a
20-minute verify window would produce exactly this: a small error count (1–3),
on a random guest, every week, with **no chunk ever proven corrupt**.

This hypothesis is strongly supported by `still-bad: 0` / `removed-bad: 0`. When
PBS proves a chunk's digest is wrong it marks it `.bad` and GC counts it. GC is
counting **zero**, across months of failures. Either the marking does not happen
on the S3 backend, or nothing has ever actually been proven corrupt.

If H1 holds, the backups are restorable, the verify job is the flaky component,
and the fix is retry/timeout tuning (or a PBS bug report) — not data recovery.

**H1 has a strong specific form: the PBS version.** This store has run
**4.1.1 (January 2026)** against an S3 backend for its entire life, while
upstream has shipped **four** releases since (4.2.1 → 4.2.4). S3-backed
datastores are new enough that client-side retry, error handling, and chunk
read-back are exactly the areas likely to have been fixed. Before doing anything
elaborate, **check the 4.2.x changelogs for S3 fixes and upgrade** — that is a
one-command test of the most probable cause.

### H2 — Chunks are genuinely corrupt at write time

The alternative: something between the source read and the R2 PUT is corrupting
data — truncated uploads that PBS accepts, the local `r2-cache` on the saturated
HDD pool returning bad data before upload, or memory errors on the PBS host.

If H2 holds, a rotating random subset of every night's backups is **silently
unrestorable**, and the only reason it looks contained is that `keep-last=1`
prunes the evidence every night.

**Do not assume H1 because it is the comfortable one.** The whole point of
Phase 1 is to distinguish them, and it is cheap.

---

## Phase 1 — Distinguish H1 from H2 — ✅ DONE 2026-08-01

Answered by the two-run experiment above, not by the steps below (1.1 and 1.4
were never needed). Kept for reference. **The decisive command was:**

```bash
# clean — 0 errors on every group it reached
proxmox-backup-manager verify r2-store --ignore-verified false
# 3 of 5 groups fail, same snapshots, one hour later
proxmox-backup-manager verify r2-store --ignore-verified false \
  --read-threads 16 --verify-threads 16
```

Run it in `tmux` — the CLI's worker dies with the SSH connection.

### Original plan (superseded)

- [ ] **1.1 Get the actual per-chunk error text.** The task logs record only the
      summary (`… (3 errors)`) — the individual failures are not in there. On the
      PBS host:
      ```bash
      journalctl -u proxmox-backup-proxy --since "2026-08-01 01:15" --until "2026-08-01 01:45" | grep -Ei 'chunk|verify|s3|bad'
      ```
      **This is the whole question.** `digest mismatch` / `wrong digest` ⇒ H2.
      `load failed`, `error reading`, timeout, or an HTTP status ⇒ H1.
- [ ] **1.2 Re-verify the known-bad snapshot by hand.** `ct/104`'s 2026-07-28
      snapshot is still present and still marked failed:
      ```bash
      proxmox-backup-manager verify r2-store --ns '' ct/104/2026-07-28T01:38:15Z
      ```
      **If it passes on a second run, that is H1 confirmed** — the data is fine
      and the failure was transient. If it fails again on the same chunks, H2.
      This is the single highest-value command in this document.
- [ ] **1.3 Check whether `.bad` chunks exist at all.** Reconciles the
      `still-bad: 0` reading and tells us whether PBS's corruption bookkeeping
      even functions on an S3 backend.
      ```bash
      proxmox-backup-manager datastore show r2-store
      find /mnt/datastore/r2-cache -name '*.bad' | head
      ```
- [ ] **1.4 Rule out host memory.** Cheap, and it is the classic cause of
      write-time chunk corruption. Check whether the PBS host's RAM is ECC and
      whether anything has been logged:
      ```bash
      journalctl -k | grep -Ei 'edac|machine check|mce|memory error'
      ```

## Phase 2 — Fix the notifications (independent, do it regardless)

Three months of weekly failures went unseen. That is the actual failure here —
the corruption question is unresolved, but the *detection* is definitively
broken.

- [ ] **2.1** Inspect the notification config — matcher, endpoint, and whether
      the target still authenticates:
      ```bash
      cat /etc/proxmox-backup/notifications.cfg
      proxmox-backup-manager notification endpoint list
      ```
- [ ] **2.2** Send a test notification and confirm it arrives.
- [ ] **2.3** Route PBS failures somewhere that is actually read. The homelab
      already has Home Assistant push via `mcp_axon_gateway_hamcp_call_service`
      ([[cron-result-delivery]]) — a webhook endpoint into HA is the path of
      least resistance and lands on a phone.
- [ ] **2.4** Consider a Prometheus alert as a backstop, independent of PBS's own
      notifier. `otel` already scrapes the fleet.

## Phase 3 — Apply the fix

- [ ] **3.1 Set `# of Read Threads` to 1 and `# of Verify Threads` to 4.** GUI:
      Datastore → `r2-store` → Verify Jobs → edit job `v-b4b3326e-0c8d` (the
      fields are under the **Advanced** checkbox). Those are the PBS defaults and
      exactly the configuration that produced 0 errors on 2026-08-01.
      Read threads are the ones that matter — the failure is in the HTTP read,
      not the hashing — but there is no reason to keep verify threads at 16
      either. A single-threaded full verify takes ~90 min, irrelevant for a
      weekly `sat 01:15` job. **Nobody knows where 16 came from**; it is not a
      PBS default.
- [ ] **3.2 Upgrade PBS 4.1.1 → 4.2.4.** Seven months and four releases behind,
      on a backend that is new upstream. "Retry a failed object read instead of
      failing the whole snapshot" is exactly what gets fixed in a young S3
      client. Read the 4.2.x changelogs for S3 entries before assuming.
- [ ] **3.3 Only after both:** optionally re-test at 16 threads. If 4.2.4 handles
      it cleanly the concurrency can go back up; if it still fails, that is a
      clean upstream bug report — *verification reports corruption on transient
      object-storage read failures instead of retrying* — with a reproducer.
- [ ] **3.4 Re-check the `journalctl` output** (Phase 1.1) to confirm whether the
      failed reads were S3 GETs or local cache reads. Does not change the fix;
      decides how the upstream report is worded.

---

## Do this now, regardless of hypothesis

- [x] **Raise retention off `keep-last=1`.** ✅ Done 2026-08-01 — nightly job is
      now `keep-daily=7` + `keep-weekly=4`, immich job `keep-last=4`. A one-deep retention on a store with
      a known verification problem means every night destroys the previous
      (possibly good) copy and the only surviving snapshot may be the bad one.
      This is a two-minute change in the PVE backup job and it buys a fallback.
- [ ] **Do one real restore.** Still open — tracked in
      [Still open](#still-open) above. Nothing in this document proves a backup
      is restorable. Restore `ct/102` (pocketid, 1.9 GB — the cheapest) to a
      scratch guest and confirm it boots. Verification passing is not the same
      as a restore working, and as of 2026-08-09 verification has been
      demonstrated but a restore has not.

## Verification

- The per-chunk error text is known and H1/H2 is settled.
- A verify run completes with `TASK OK` — which has not happened in months.
- A deliberately triggered failure produces a notification that reaches a phone.
- One restore has been performed end to end.

## Risks

- **`keep-last=1` is actively hostile here.** It prunes the evidence needed to
  diagnose this before anyone looks at it, and it means there is no second copy
  when the first fails verification.
- **`still-bad: 0` is not reassurance.** It is equally consistent with "nothing
  is corrupt" and "PBS is not tracking corruption on this backend". Do not read
  it as an all-clear until 1.3 says which.
- **The one snapshot we can still test will be pruned.** `ct/104` is
  `keep-last=2` and the next run is 2026-08-02 01:00; the 07-28 snapshot survives
  that run but not the one after. **Do 1.2 before 2026-08-09**, or mark the
  snapshot protected to keep it.
- **Immich has no verified backup at all right now.** Its only snapshot is the
  failing one. Until 1.2 resolves, treat the running CT 104 as the sole copy.

## Related

- [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md) — separate problem
  (backup *speed*), same datastore. That migration does not fix this.
- [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md) — records the
  `backend type=s3` finding and cleared PBS GC as a concern. If H2 implicates the
  `r2-cache` on the HDD pool, Phase 4 of that document (moving the cache to SSD)
  becomes relevant to this one.
- [[pve-storage-hdd-bottleneck]] — the standing storage diagnosis.
