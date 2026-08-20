# Deployment Status

Status for the current rollout of the latest NixOS changes on 2026-08-18.

This is the **Comin deployment**. Once Comin is successfully deployed on a VM,
that VM polls the canonical Forgejo Git repository and applies updates from the
`main` branch automatically. Future configuration changes therefore deploy via
Git after they are merged, instead of requiring a manual deployment on every
machine.

## Latest commits (2026-08-20, on top of `9cd05ec`)

Three commits landed on `main` after the state this doc otherwise describes:

- `22d4528 fix(tempo): v3 syntax` — otel's Tempo config (`hosts/otel/configuration.nix`)
  predated the `services.tempo.package` bump to **3.0.2**, which removed the
  `compactor` component and v2 block encoding entirely. Tempo's strict decoder
  was rejecting `compactor.*` and `storage.trace.block.v2_encoding` /
  `v2_index_downsample_bytes` as unknown fields, so `tempo.service` never
  started (`field compactor not found`, `field v2_encoding not found`).
  Retention moved to `backend_worker.compaction.block_retention`
  (`tempodb.CompactorConfig`). Verified directly against the real
  `tempo-3.0.2` binary (`-config.file=... `, ran to the
  `mkdir /var/lib/tempo: permission denied` line, i.e. config parsed and the
  app started) — not just a green `colmena build`.
- `d20dc58 fix(attic): add secret nonce restart dependency` — `attic-login.service`
  (`modules/attic-push.nix`) is `RemainAfterExit = true` and its `ExecStart`
  only references the decrypted secret's stable *path*, never its content, so
  NixOS never restarted it when `attic-push-token.age` was rekeyed (recipients
  widened to every comin host in `7476076`/`fd6fdf7`, 2026-08-19). Hosts where
  the login unit had already succeeded once kept using whatever token was live
  at their last activation/boot — this is what produced `otel`'s
  `AccessError: User does not have permission to complete this action.` on
  `attic-push-system.service` (confirmed via Loki: exactly one push attempt
  ever logged, zero `attic-login` logs in 7 days). `fleet`'s attic-push failure
  the same day was unrelated — a transient `Connection timed out (os error
  110)` to `cache.homelab.local:443` partway through a push, with most objects
  (including the system closure itself) uploading fine before it; Prometheus
  showed `cache-node` and the `cache.homelab.internal` HTTPS probe both healthy
  at the time, so no code fix was needed there, just a retry on the next
  deploy. The fix adds a `secretNonce` (dated `2026-08-20-attic-push-token-rekey`)
  wired into `attic-login.service`'s `restartTriggers`, so any future token
  rotation forces a restart on the next deploy instead of silently going stale
  — the same pattern already used for `hermes`/`mcp_vm` secrets (see AGENTS.md
  §3, "Systemd restart nonces").
- `4c42656 feat(caddy): open UDP/443 for HTTP/3 (QUIC) on all Caddy hosts` — new
  `modules/caddy-http3.nix` (`networking.firewall.allowedUDPPorts = [443]`),
  imported into 17 hosts' `configuration.nix`. Caddy advertises `h3` via
  `alt-svc`, but the NixOS firewall was dropping QUIC packets since nothing
  opened UDP/443 declaratively before this.

### `4c42656` host rollout

Of the 17 hosts touched, only 15 are live, deployable targets — confirmed
against `nix eval .#colmenaHive.nodes`:

| Host | In `colmenaHive`? | Auto-deploys via comin? |
| --- | --- | --- |
| ca, cache, containers, database, development, dns, fleet, forgejo, harbor, hermes, jellyfin, mcp, otel, unifi, woodpecker | ✅ | Only `cache`/`containers`/`forgejo`/`development` are confirmed *actively polling* (`job="comin"` in Loki, per the section below); the rest need a manual `colmena apply` nudge unless/until their comin logging is confirmed live too. `hermes` never completed its comin bootstrap (see "Failed" above) and `jellyfin` is currently unreachable (`No route to host`) — both need investigation independent of this firewall change. `database` is still listed "Still To Deploy". |
| buildbot-master, buildbot-worker-1 | ❌ (no `hostAddrs` entry, no hive node) | Never — the change lands in their `nixosConfiguration` (both are `mkHost`-based) but there is no live target to push it to. Not a bug, just dead weight in those two configs until/unless the hosts are actually provisioned. |

`zeroclaw` also carries `caddy-http3.nix` at the `nixosConfigurations` level
(same `mkHost` path) but wasn't in this commit's changed-file list and its
`colmenaHive` entry is commented out — same "not a live target" situation as
the two buildbot hosts, just pre-existing rather than newly introduced.

**Confirmed via Loki, 2026-08-20T09:37–09:38 UTC**: both `cache` (09:38:25) and
`mcp` (09:37:45) fetched and began evaluating `4c42656` (`manager: a
generation is evaluating for commit 4c42656b6...`). Neither logged a build or
switch error afterward — comin doesn't emit an explicit "activated"/"success"
line in this version, so this is inferred from the absence of any error until
the unrelated incident below, not a positive confirmation. The axon-gateway
MCP (which fronts the Loki queries used for this doc) then went fully
unreachable for several minutes (`Unknown tool` for every tool group, not just
Loki), matching the documented axon-gateway-drops-prometheus-backend-on-otel-deploy
pattern — otel's own `colmena apply`/comin deploy of the tempo/attic fixes
above restarts Loki, which trips the gateway's circuit breaker. It recovered
on its own; no restart needed.

**Separate, self-resolved incident, 09:52–10:05 CEST**: once the gateway was
back, Loki showed a burst of `comin` git-pull failures against
`forgejo.homelab.local` on **six** hosts — `cache`, `mcp`, `containers`,
`development`, `forgejo` (itself, pulling from its own external hostname),
and `otel` — with a mix of error shapes (`context deadline exceeded`, `TLS
handshake timeout`, one `502` on `development`, and DNS resolution failures
—`Temporary failure in name resolution` on `forgejo`, `i/o timeout` on a DNS
lookup from `otel`). The mix of DNS-lookup and TLS/502 failures across
unrelated hosts, including forgejo failing to resolve its own name, points at
either the `dns` host (unbound) or forgejo's Caddy vhost being transiently
overloaded — not any single host's own state. It self-recovered: no further
`comin` errors after `cache`'s last one at 10:05:26 CEST, and Prometheus's
`blackbox-http_2xx` probe for `https://forgejo.homelab.local` was healthy
again by 10:31. This is a bigger repeat of the isolated `502` noted earlier in
this doc (2026-08-19, hit `cache`/`containers` once each) — still not
diagnosed further, but now a second occurrence, so worth watching if it
recurs a third time.

**Net effect on rollout**: `cache` and `mcp` almost certainly deployed
`4c42656` (evaluation started cleanly, no error followed); `containers` and
`forgejo`'s own eval of `4c42656` specifically wasn't caught in the logs
before the pull-failure incident, and `development` and `otel` weren't
confirmed evaluating it at all yet as of this check. Re-run the propagation
check (`{job="comin"} |~ "(?i)(evaluating for commit|switch|activat)"`) later
to fill in the remaining hosts once comin's next poll cycle runs.

**Opening UDP/443 does not by itself prove HTTP/3 is being negotiated.** Once
a host's firewall change lands, smoke-test it rather than assuming the port
being open is sufficient:

```bash
curl --http3 -v https://<vhost> 2>&1 | grep -i "using http/3\|alt-svc"
# or, from any client: check the response carries `alt-svc: h3=":443"; ...`
```

## Mitigations for the 09:52–10:05 DNS/forgejo incident (not yet committed)

Two follow-up changes, staged locally but not yet on `main`, address the root
cause of the pull-failure burst documented above rather than just noting it:

- **`modules/dns-client-cache.nix`** (new, imported into `modules/common.nix`
  for every host): every host previously queried the `dns` host's unbound
  directly over the network with **zero local caching** — plain glibc
  resolver via `networking.nameservers`, no `systemd-resolved`/`nscd`. A
  single brief hiccup on `dns` or the network path to it therefore failed
  every in-flight lookup on every host at once, which is exactly what the
  09:52–10:05 burst looked like. This adds a local unbound stub-resolver on
  every host *except* `dns` itself (guarded on `networking.hostName !=
  "homelab-dns"` — `dns` keeps its own full authoritative instance
  unmodified), forwarding to `192.168.2.145`/`192.168.2.1`, with
  `serve-expired = true` (stale cached answers are served immediately if the
  upstream is slow instead of failing the client) and `cache-min-ttl = 1800`
  (30-minute floor on retention regardless of the record's own TTL).
  `networking.nameservers` is repointed to `127.0.0.1` so lookups go through
  the local cache. Verified against the actual generated
  `/etc/unbound/unbound.conf` on `otel`, not just a green build.
- **`modules/comin.nix`**: `services.comin.remotes.*.poller.period` has no
  jitter option, so every comin host was polling forgejo independently on the
  same 60s default — ~15 uncoordinated git-fetch requests/minute that can
  drift into phase and hit forgejo in the same few seconds, which is the
  likely trigger for the incident (comin polling is what generates the
  request load in the first place). Each of the 15 live hive hosts now gets a
  distinct `poller.period` (60–130s, 5s apart: `ca`=60, `cache`=65,
  `containers`=70, `database`=75, `development`=80, `dns`=85, `fleet`=90,
  `forgejo`=95, `harbor`=100, `hermes`=105, `jellyfin`=110, `mcp`=115,
  `otel`=120, `unifi`=125, `woodpecker`=130), so they drift apart over time
  instead of staying in phase. Non-hive hosts (`buildbot-master`,
  `buildbot-worker-1`, `zeroclaw`) fall back to 60s via `pollerPeriods.${hostname}
  or 60` — harmless since they're not live deploy targets (see the `4c42656`
  host-rollout table above). Verified `otel`'s generated
  `services.comin.remotes` shows `poller.period = 120`.

Both changes build clean (`just colmena-build-host otel`, `just
colmena-build-host dns`) and are staged in the working tree, not yet
committed or deployed. **This means the rollout tracking above (`4c42656`
host table, propagation status) will shift again once these land** — every
comin host's poll cadence changes, so re-check propagation after deploying
rather than assuming the 60s-default timing described above still holds.

## Completed (comin active)

These VMs have been bootstrapped and **`comin.service` is `active`**, polling
Forgejo and auto-deploying from `main`. See `docs/comin-findings-2026-08-18.md`
for details on comin behavior and the harmless `HEAD outside of refs/` warning.

On 2026-08-19, `containers`, `mcp`, `fleet`, `cache`, and `otel` were found
stuck several commits behind: comin evaluates each host's own config **on
that host**, and low free RAM (confirmed on `containers`: 145MB free of
1.6GB, 1.4GB swap in use, journald logging memory-pressure flushes) was
causing comin's on-host evaluation of `main` to fail outright — not a flake
regression (`nix build`/`colmena build` for the same commit succeeded
cleanly from the controller both then and now). This also explained the
attic-push failures below: `cache` itself was one of the stuck hosts, so
pushes to it errored. Fixed same-day by running `colmena apply --on <host>`
for each (`fd6fdf7`), which builds on the controller and only pushes/activates
remotely, sidestepping the target's eval-memory problem. All 5 confirmed
via successful `colmena apply` output; `cache` and `containers` were further
confirmed live via `readlink -f /run/current-system` matching the deployed
store path. `comin status` on both still shows a stale "Evaluation failed"
against `fd6fdf7` from before the fix — that's comin's own bookkeeping,
which a colmena-driven switch bypasses entirely (it doesn't go through
comin's deployer), not evidence anything is currently wrong. `otel`, `mcp`,
and `fleet` weren't independently re-verified this session.

- `otel` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active; re-deployed 2026-08-20
- `containers` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active
- `dns` — version `26.11pre-git` (updated 2026-08-18); comin active, evaluating latest commit
- `mcp` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active; re-deployed 2026-08-20
- `fleet` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active; re-deployed 2026-08-20
- `cache` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active

`containers` is a VM. The containerized services running on it are covered by
that VM deployment.

## In Progress

- `dns` — deploying via `colmena apply` (2026-08-20)
- `forgejo`

## Failed

- `hermes`

Investigate the failed `hermes` activation before retrying its deployment.
Comin is not considered active on `hermes` until this bootstrap deployment
succeeds.

## Still To Deploy

- `containers` — comin-agent inactive, needs manual `colmena apply` or service start
- `cache` — comin-agent inactive, needs manual `colmena apply` or service start
- `database`
- `unifi`
- `ca`
- `harbor`
- `woodpecker`
- `development`
- `jellyfin`

All entries above are VMs managed by the Colmena hive. `minimal` and `iso` are
installer images, not deployment targets.

## Host reachability sweep (2026-08-19, `just cs <host>`)

Ran `just cs <host>` (`colmena exec --on <host> -- readlink -f /run/current-system`)
against every active `colmenaHive` node to confirm each is reachable and
report its current running system store path. This only shows what is
currently booted/activated on each host — it does **not** by itself confirm
the host is current with `main` HEAD; cross-reference with the comin sections
above for that.

| Host | Reachable | Current system store path |
| --- | --- | --- |
| database | ✅ | `nixos-system-homelab-database-26.11pre-git` (`3bdmc5f0…`) |
| otel | ✅ | `nixos-system-homelab-otel-26.11pre-git` (`jhvmwq84…`) |
| dns | ✅ | `nixos-system-homelab-dns-26.11pre-git` (`xr7bw3sk…`) |
| unifi | ✅ | `nixos-system-homelab-unifi-26.11pre-git` (`x7m65s1w…`) |
| containers | ✅ | `nixos-system-homelab-containers-26.11pre-git` (`y2sq2pnw…`) |
| mcp | ✅ | `nixos-system-homelab-mcp-26.11pre-git` (`2nkci28j…`) |
| hermes | ✅ | `nixos-system-homelab-hermes-26.11pre-git` (`3g2h24fa…`) |
| ca | ✅ | `nixos-system-homelab-ca-26.11pre-git` (`vl4g9ars…`) |
| fleet | ✅ | `nixos-system-homelab-fleet-26.11pre-git` (`879aa7bg…`) |
| harbor | ✅ | `nixos-system-homelab-harbor-26.11pre-git` (`r31j14kf…`) |
| cache | ✅ | `nixos-system-homelab-cache-26.11pre-git` (`2y14p4g2…`) |
| forgejo | ✅ | `nixos-system-homelab-forgejo-26.11pre-git` (`w764s4xd…`) |
| woodpecker | ✅ | `nixos-system-homelab-woodpecker-26.11pre-git` (`qv4604fg…`) |
| development | ✅ | `nixos-system-homelab-development-26.11pre-git` (`cc94bnc0…`) |
| jellyfin | ❌ | `ssh: connect to host jellyfin.homelab.local port 22: No route to host` |

Notable deltas from the sections above:

- `hermes` **is** reachable and has an activated system, despite the
  "Failed" status recorded above — that note predates this sweep, so the
  earlier bootstrap failure appears to have been resolved or superseded
  since it was written. Still worth confirming `comin.service` actually
  exists and is active there before calling it done (see the note under
  "Next" below).
- `forgejo` and `woodpecker` also have an activated system already, ahead
  of their "In Progress" / "Still To Deploy" labels above — again just
  proof of reachability + a booted system, not proof it's comin-managed or
  current with `main`.
- `jellyfin` is unreachable (`No route to host`) — check the VM is powered
  on and has network before investigating anything comin-related there.

## Comin activity via Loki (2026-08-19, `job="comin"`)

Cross-checked comin's own logs in Loki (via the `axon-gateway` MCP's Loki tools)
rather than relying on the "current system" store path alone, since that only
proves a host is *booted*, not that comin is *actively* polling/deploying.

**Only 3 hosts currently ship `job="comin"` logs to Loki** — confirmed with
`loki_series({job="comin"})`:

| Host | comin logs in Loki | Latest observed activity |
| --- | --- | --- |
| `cache` | ✅ | evaluating commit `9cd05ec` (current `main` HEAD) as of 21:02:11 |
| `containers` | ✅ | evaluating commit `9cd05ec` as of 21:02:39 |
| `forgejo` | ✅ | evaluating commit `9cd05ec` as of 21:01:23 |
| `mcp`, `development`, `woodpecker` | ❌ | `host` label exists in Loki (other jobs: `wpmcp-server`, `hamcp-server`, etc.) but **no `job="comin"` stream at all** — the `39773f5` fluent-bit wiring for comin hasn't landed/restarted comin's journal shipping on these hosts yet, despite the "Next" rollout plan below listing them as already comin-active |
| `otel`, `fleet`, `dns`, `database`, `jellyfin`, `unifi`, `harbor`, `ca`, `hermes` | ❌ | not in the rollout yet (matches the plan below) |

On all three logging hosts, comin picked up `main` HEAD (`9cd05ec`) and started
evaluating it around 21:01–21:03, but **no subsequent `deployer`/activation log
line was seen afterward** (checked with a `(?i)(activat|switch-to-configuration|deployer)`
filter from 20:50 onward — zero matches). The last `deployer:` lines on any of
them are from each comin service's own startup at 18:54:23-ish, initializing
against the *already-booted* store path.

**Follow-up (2026-08-20): re-checked `cache`, `containers`, and `forgejo` —
the identical store path is expected, not a stalled deploy.** All three still
report the exact same `/run/current-system` path as the initial sweep
(`cache` → `2y14p4g2…`, `containers` → `y2sq2pnw…`, `forgejo` → `w764s4xd…`),
and comin's journal on `cache`/`containers` has gone completely quiet in the
hour since (no eval, no retention-pruning lines — because `main` hasn't moved
past `9cd05ec`, so there's nothing new to fetch).

Traced why the store paths didn't change even though comin *did* evaluate
`3acc567` and `9cd05ec`: both commits only touch `secrets/secrets.nix` (a new
agenix recipients entry) and add `secrets/ventara-gateway-env.age`.
`secrets/secrets.nix` is the `agenix` CLI's own rules file — it is **not**
imported by any `nixosConfigurations`/`colmenaHive` build, so editing it
cannot change any host's closure. The new `.age` file is consumed by exactly
one host: `grep -rl ventara-gateway hosts/` matches only
`hosts/development/configuration.nix` (`modules/coding-harness.nix` gates on
`config.age.secrets ? ventara-gateway-env`, true only there). So `cache`,
`containers`, and `forgejo` never had a reason to rebuild for these two
commits — comin correctly evaluated them, found no relevant change, and
produced no new generation. This was a false alarm from the earlier check;
the real place to verify a deploy from these commits landed is `development`,
the one host that actually references the new secret — not the three
comin-logging hosts checked here.

Also of note: an isolated `502 Bad Gateway` pulling from
`forgejo.homelab.local` hit both `cache` (19:17:35–19:17:41) and `containers`
(13:11:16) today — each only once, self-recovered on the next poll. Not
currently a pattern, but worth remembering if pull failures recur across
multiple hosts at the same time (points at forgejo itself, not per-host state).

## Next: Loki logging rollout (commit `39773f5`)

`39773f5` wires `comin.service` / `attic-login.service` /
`attic-push-system.service` journals into the central Loki via
`modules/comin.nix` and `modules/attic-push.nix` (see
`modules/loki-logs.nix`), so fetch/eval/deploy results and push failures
become queryable centrally instead of needing SSH per host. This touches
every comin host, including several that never ran fluent-bit before
(`otel`, `fleet`, `dns`, `unifi`, `harbor`, `ca`, `development`) — a new
steady-state service on hosts already shown to run low on memory (see
above). `modules/loki-logs.nix` itself warns fluent-bit's YAML plugin
schema is NOT validated at build time, only at runtime.

Don't rely on comin's own poll cycle to roll this out — apply manually in
this order, checking `systemctl status fluent-bit` after each, and once
confirmed once, checking `{job="comin"}` / `{job="attic-push"}` /
`{job="attic-login"}` show up in Loki:

1. `containers` — validation target. Already comin-active/current and
   already runs fluent-bit (axon-gateway logs), so this only adds one
   incremental unit. Also the most memory-constrained host confirmed so
   far (145MB free earlier today) — if it handles the extra unit fine,
   everything else should too.
2. `cache` — validates the `attic-login`/`attic-push` vs. `attic` (the
   atticd server's own job) name split, on the one host running all three.
3. `mcp`, `forgejo` — already comin-active and already running fluent-bit
   for their own services.
4. `otel`, `fleet`, `dns` — comin-active, but first time running
   fluent-bit at all.
5. `database`, `jellyfin`, `woodpecker` — not yet bootstrapped, but
   already import `loki-logs.nix` for their own services, so this only
   bootstraps comin, not fluent-bit.
6. `unifi`, `harbor`, `development` — not yet bootstrapped and never ran
   fluent-bit before; comin and Loki shipping land simultaneously here.
7. `ca` — hold until the SSH banner-exchange hang from 2026-08-19 is
   understood; don't add more load to a host that's already timing out on
   basic connections.
8. `hermes` — separate track. Its original comin bootstrap never
   completed (`comin.service` doesn't exist on the host at all);
   investigate with `colmena apply --on hermes -v` before retrying,
   independent of this logging change.
