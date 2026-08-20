# Deployment Status — 2026-08-20

Snapshot of the comin/colmena fleet as of 2026-08-20, ~15:00 CEST (refreshed
with a concrete per-host store-path drift check; the ~11:45 snapshot's rollout
claims below were inferred from Loki and only partially held up under direct
verification). Supersedes `docs/deployment-status-2026-08-18.md` (deleted; git
history has the full blow-by-blow if needed).

This is the **Comin deployment**, with **colmena as the manual push path for
hosts that need human action**. Once Comin is active on a VM, that VM polls the
canonical Forgejo Git repository and applies updates from `main` automatically.

## `main` HEAD: `98f29e7`

Commits landed on `main` today, on top of yesterday's `9cd05ec`:

| Commit | What | Why |
| --- | --- | --- |
| `22d4528` | `fix(tempo)`: v3 config syntax | Tempo bumped to 3.0.2, which removed the `compactor` component and v2 block encoding; retention moved to `backend_worker.compaction.*`. Verified against the real `tempo` binary, not just a green build. |
| `d20dc58` | `fix(attic)`: secret-nonce restart trigger | `attic-login.service` never restarted on token rotation (stable secret *path*, not content, in `ExecStart`) — root cause of `otel`'s `attic-push-system` `AccessError`. |
| `4c42656` | `feat(caddy)`: open UDP/443 for HTTP/3 | New `modules/caddy-http3.nix`, on 17 hosts (15 live, see below). |
| `5552b2e` | `feat(dns)`: local unbound client-cache + staggered comin polling | First cut — see below, needed 3 follow-up fixes. |
| `1cf6a66` | `chore(docs)`: deployment status update | The doc this one replaces. |
| `3ff0a83`, `a89c96d`, `28ce2fa`, `cfc382f` | `fix(dns)` / `fix(metrics)` ×4 | Follow-up fixes to `5552b2e`, see below. |
| `3104f60` | `docs`: replace deployment status with this doc's 11:45 snapshot | Docs only; no Nix effect. |
| `98f29e7` | `fix(iac)`: raise harbor memory to 2GiB, ballooning off | Harbor wedged on 2026-08-20 when Proxmox ballooned the VM down to 768 MiB (`floating=768` < the memory harbor's containers actually need). `dedicated = floating = 2048` so the balloon can never shrink it. IaC only — requires `tofu apply`, does **not** touch harbor's system closure. |

No Nix config changed between `cfc382f` and `98f29e7` — so a host caught up to
`cfc382f` is, at the Nix level, caught up to `main` HEAD.

### The DNS client-cache saga (`5552b2e` → `cfc382f`)

Triggered by a real incident: a comin-poll burst on 2026-08-20 09:52–10:05
caused a ~13 min run of DNS/forgejo pull failures across six hosts at once,
because every host queried the `dns` host's unbound directly with **zero
local caching**. Fix: `modules/dns-client-cache.nix`, a local unbound stub on
every host except `dns` itself, with `serve-expired` + a 30 min
`cache-min-ttl` floor. Also staggered `services.comin.remotes.*.poller.period`
per host (60–130s, `modules/comin.nix`) so ~15 hosts stop hammering forgejo
in the same few seconds.

Getting the stub actually correct took three more commits, each caught by
running the *real* generated config against the real `unbound`/`dig` binaries
— a green `colmena build` only proves Nix wrote a config file, not that
unbound accepts or correctly answers from it:

- **`3ff0a83`** — unbound auto-treats `local.` (RFC 6762 mDNS) and `internal.`
  (RFC 9476) as reserved TLDs and NXDOMAINs them internally. Needed both a
  `local-zone: <tld> transparent` override *and* a dedicated `forward-zone`
  for each TLD (not just the catch-all `.`) — the override alone falls
  through to real root-server iteration instead of the configured forwarder.
- **`a89c96d`** — the stub's `networking.nameservers = ["127.0.0.1"]`
  clobbered Tailscale's dynamically-inserted `100.100.100.100` MagicDNS
  entry, breaking `*.ts.net` resolution (caught live: `git push` over the
  Tailscale SSH remote failed right after the first deploy). Added an
  explicit `forward-zone` for `ts.net.` → `100.100.100.100`.
- **`28ce2fa`** — unrelated pre-existing bug surfaced by the same activation:
  `modules/nixos-version-metrics.nix`'s activation script called bare `sed`,
  which isn't reliably on an activation script's PATH. Now uses
  `${pkgs.gnused}/bin/sed`.
- **`cfc382f`** — **the actual root cause of the intermittent failures chased
  for over an hour**, misread at first as network flakiness to the `dns`
  host: unbound's DNSSEC `validator` module SERVFAILs answers from these
  unsigned private zones instead of passing them through. Confirmed with
  `dig +cd` (skip validation) succeeding on a query that had just SERVFAILed
  normally, network conditions unchanged. Fixed with `domain-insecure` for
  `local.` / `internal.` / `ts.net.`.

**Directly verified on `development`** (not just built): `dig`/`curl` for
`.local`, `.internal`, and `.ts.net` names all resolve correctly on first
try; `git push`/`git fetch` work; `unbound-checkconf` passes on the live
generated config.

## Host rollout status

15 hosts are live `colmenaHive` targets (confirmed via
`nix eval .#colmenaHive.nodes`): `ca`, `cache`, `containers`, `database`,
`development`, `dns`, `fleet`, `forgejo`, `harbor`, `hermes`, `mcp`, `otel`,
`unifi`, `woodpecker` (plus `jellyfin`, which pings DOWN). `buildbot-master`
and `buildbot-worker-1` have no `hostAddrs` entry or hive node, so changes land
in their `nixosConfiguration` but nothing will ever deploy them there.

The original ~11:45 snapshot claimed via Loki that `cache`, `mcp`, `containers`,
`forgejo`, `otel`, `development` were "reaching `cfc382f`". A direct store-path
sweep (~15:00) **contradicted most of that** — Loki shows comin *evaluating*
commits, not that the activation succeeded. This table is authoritative; it was
produced by comparing `readlink -f /run/current-system` on each host against
the toplevel closure that `main` currently evaluates to.

### ⚠️ Two closure families complicate the comparison

`nix build .#nixosConfigurations.<host>` and `nix build
.#colmenaHive.nodes.<host>...` currently produce **different** toplevel
closures: the `26.11.20260813.0e251e2` suffix (nixosConfigurations) vs
`26.11pre-git` (colmenaHive). The hive's `meta.nixpkgs = import nixpkgs` loses
the flake's `self.rev`/`lastModified`, which nixpkgs embeds in its `version`
attribute, so the store path necessarily differs even for identical config —
but that makes the two outputs **not bit-identical closures**. Since comin
builds `nixosConfigurations` and colmena deploys the hive, the two tools can
disagree about "up to date" for the same host. Do not decode the suffix alone;
compare full store paths.

### Per-host sweep (against the **hive** closure colmena would push)

| Host | Running (from host) | Matches current `main`? |
| --- | --- | --- |
| development | `4qx5987…26.11.20260813.0e251e2` | ✅ matches a current nixosConfiguration-family build |
| woodpecker | `b7xzb29…26.11.20260813.0e251e2` | ✅ matches current build (deployed manually today) |
| harbor | `mvcv76wm…26.11pre-git` | ✅ matches current hive closure (deployed manually today) |
| cache | `vmird4gb…26.11.20260813.0e251e2` | ⚠️ older build, **not** current |
| containers | `y2sq2pn…26.11pre-git` | ⚠️ older pre-git closure |
| forgejo | `w764s4x…26.11pre-git` | ⚠️ older pre-git closure |
| hermes | `3g2h24f…26.11pre-git` | ⚠️ older pre-git closure |
| otel | `dwq5sddp…26.11pre-git` | ⚠️ older pre-git closure |
| database | unreachable (SSH timeout) | ❓ unknown — likely stale |
| dns | unreachable (SSH timeout) | ❓ unknown — likely stale |
| unifi | unreachable (SSH timeout) | ❓ unknown — likely stale |
| ca | unreachable (SSH timeout) | ❓ unknown — SSH hang known since 2026-08-19 |
| fleet | unreachable (SSH timeout) | ❓ unknown |
| mcp | unreachable (SSH timeout) | ❓ unknown |
| jellyfin | `No route to host` | 💀 **down** |

**Reachability nuance:** *all* of the "unreachable" hosts above respond to
`ping` (they are powered and on-LAN); they dropped out at the SSH layer
(connect timeout on port 22), so this is an SSH/DNS-deploy-path problem, not
powered-off VMs. `dns` is the resolver every other host depends on — its own
SSH being unreachable while ping works is the single most concerning item in
this list (same symptom family as the `ca` 08-19 banner-exchange hang).

### Where things stand

- **Up to date (3):** `development`, `woodpecker`, `harbor`. Woodpecker and
  harbor were pushed manually today via `colmena apply` — the only hosts this
  session directly converged.
- **Stale (5):** `cache`, `containers`, `forgejo`, `hermes`, `otel` — all
  running closures older than the DNS-saga chain (`5552b2e`→`cfc382f`). Their
  comin poll did not land the chain despite Loki showing evaluations.
- **Unknown (6):** `database`, `dns`, `unifi`, `ca`, `fleet`, `mcp` — SSH is
  unreachable, so neither comin *nor* colmena can converge them until that is
  fixed. **`dns` first** (it is the resolver everything else trusts).
- **Down (1):** `jellyfin` — no route to host; VM off or networking down.

**Recommended next action:** fix SSH to `dns` (and the other unreachables), then
`just colmena-apply` — the 5 stale hosts should converge on their own after
`dns` is healthy, and the unknowns become visible.

## Known open items

- **SSH layer unreachable on 6 hosts despite ping UP** (`database`, `dns`,
  `unifi`, `ca`, `fleet`, `mcp`) — same symptom family as the `ca` 08-19
  banner hang, now widespread. Investigate SSH daemon / fail2ban / network path
  (Tailscale vs LAN) before anything deploy-shaped.
- **jellyfin down** — `No route to host`. VM may be off; matches the earlier
  snapshot.
- **Harbor memory fix is IaC-side only** — `98f29e7` needs `tofu apply` to
  actually take effect on the VM (currently pending in `iac/`).
- **Recurring forgejo pull failures**: two occurrences now (2026-08-19 isolated
  502s on `cache`/`containers`; 2026-08-20 09:52–10:05 six-host burst with mixed
  DNS/TLS/502 errors, `forgejo` itself failing to resolve its own name). Root
  cause not identified — could be the `dns` host or forgejo's Caddy vhost under
  transient load. Watch for a third occurrence.
- **HTTP/3 not smoke-tested anywhere yet.** Opening UDP/443 doesn't confirm
  Caddy is negotiating `h3` — check per-host with:
  ```bash
  curl --http3 -v https://<vhost> 2>&1 | grep -i "using http/3\|alt-svc"
  ```
- **`attic-push-system` stale unit warning** surfaced on woodpecker's
  deploy ("Unit not found") — harmless stale trigger, not a live failure.
- **Resolved since the 11:45 snapshot:** the axon-gateway MCP health — it
  recovered and served this session's Loki/prometheus queries fine; the earlier
  "stuck" report was transient. (Axon-gateway MCP listed here as previously
  degraded 2026-08-20 ~11:15–13:00.)

## Reference: live verification commands

```bash
# Colmena reachability + current store path (bypasses comin/Loki entirely)
just cs <host>   # colmena exec --on <host> -- readlink -f /run/current-system

# Comin propagation via Loki (needs the axon-gateway MCP)
{job="comin"} |~ "(?i)(evaluating for commit|New commits)"
{job="comin", host="homelab-<host>"} |~ "(?i)(switch|activat|error)"
```
