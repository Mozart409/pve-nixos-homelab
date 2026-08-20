# Deployment Status — 2026-08-20

Snapshot of the comin/colmena fleet as of 2026-08-20, ~11:45 CEST. Supersedes
`docs/deployment-status-2026-08-18.md` (deleted; git history has the full
blow-by-blow if needed).

This is the **Comin deployment**. Once Comin is active on a VM, that VM polls
the canonical Forgejo Git repository and applies updates from `main`
automatically — no manual deployment needed once bootstrapped.

## `main` HEAD: `cfc382f`

Commits landed on `main` today, on top of yesterday's `9cd05ec`:

| Commit | What | Why |
| --- | --- | --- |
| `22d4528` | `fix(tempo)`: v3 config syntax | Tempo bumped to 3.0.2, which removed the `compactor` component and v2 block encoding; retention moved to `backend_worker.compaction.*`. Verified against the real `tempo` binary, not just a green build. |
| `d20dc58` | `fix(attic)`: secret-nonce restart trigger | `attic-login.service` never restarted on token rotation (stable secret *path*, not content, in `ExecStart`) — root cause of `otel`'s `attic-push-system` `AccessError`. |
| `4c42656` | `feat(caddy)`: open UDP/443 for HTTP/3 | New `modules/caddy-http3.nix`, on 17 hosts (15 live, see below). |
| `5552b2e` | `feat(dns)`: local unbound client-cache + staggered comin polling | First cut — see below, needed 3 follow-up fixes. |
| `1cf6a66` | `chore(docs)`: deployment status update | The doc this one replaces. |
| `3ff0a83`, `a89c96d`, `28ce2fa`, `cfc382f` | `fix(dns)` / `fix(metrics)` ×4 | Follow-up fixes to `5552b2e`, see below. |

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

15 of the 17 hosts touched by `4c42656`/`5552b2e` are live `colmenaHive`
targets (confirmed via `nix eval .#colmenaHive.nodes`); `buildbot-master` and
`buildbot-worker-1` have no `hostAddrs` entry or hive node, so the change
lands in their `nixosConfiguration` but nothing will ever deploy it there.
`zeroclaw` is in the same non-live situation (commented-out hive entry) but
wasn't touched by these commits.

**Confirmed reaching `cfc382f` (or evaluating a commit in this chain) via
Loki this session:** `cache`, `mcp`, `containers`, `forgejo`, `otel`,
`development`. `development` is fully re-verified directly on the host
(above); the other five were last seen evaluating an *earlier* commit in this
chain (`4c42656`) and have staggered poll periods now, so their exact
position in the chain as of `cfc382f` is not re-confirmed — the axon-gateway
MCP (fronts the Loki queries used for this doc) has been stuck/timing out
since ~11:15 CEST and hasn't recovered despite a `/mcp` reconnect, so this
doc could not be refreshed against live logs before writing.

**Hosts needing manual attention (`colmena apply --on <host>`), not comin:**

| Host | Why |
| --- | --- |
| `hermes` | Comin bootstrap previously reported incomplete (`comin.service` didn't exist). A later reachability sweep found an activated system there anyway — status is genuinely ambiguous, confirm `systemctl status comin` before assuming either way. |
| `jellyfin` | Unreachable (`No route to host`) as of last check — investigate power/network on the VM before any deploy method will work, comin included. |
| `database` | Never confirmed comin-active in any check this session or the prior one. |
| `ca` | SSH banner-exchange hang noted 2026-08-19, never resolved — don't add load until this is understood. |

**Unconfirmed either way** (colmenaHive members, `cominFor` applied, but no
positive `job="comin"` Loki evidence in any check this session — this may
just mean comin's Loki log-shipping isn't wired for them yet, not that comin
itself is down): `unifi`, `harbor`, `woodpecker`, `fleet`, `dns`. Worth a
`just cs <host>` reachability check or a Loki re-query once the gateway
recovers, rather than assuming either "fine" or "broken."

## Known open items

- **axon-gateway MCP stuck** since ~11:15 CEST — every tool group times out
  or fails DNS resolution, survived a `/mcp` reconnect. Needs investigation
  independent of anything above (the underlying DNS fix is confirmed correct
  by direct host-level testing, so this looks like a separate gateway/process
  issue, not a recurrence of the DNSSEC bug).
- **Recurring forgejo pull failures**: two occurrences now (2026-08-19
  isolated 502s on `cache`/`containers`; 2026-08-20 09:52–10:05 six-host
  burst with mixed DNS/TLS/502 errors, `forgejo` itself failing to resolve
  its own name). Root cause not identified — could be the `dns` host or
  forgejo's Caddy vhost under transient load. Watch for a third occurrence.
- **HTTP/3 not smoke-tested anywhere yet.** Opening UDP/443 doesn't confirm
  Caddy is negotiating `h3` — check per-host with:
  ```bash
  curl --http3 -v https://<vhost> 2>&1 | grep -i "using http/3\|alt-svc"
  ```

## Reference: live verification commands

```bash
# Colmena reachability + current store path (bypasses comin/Loki entirely)
just cs <host>   # colmena exec --on <host> -- readlink -f /run/current-system

# Comin propagation via Loki (needs the axon-gateway MCP)
{job="comin"} |~ "(?i)(evaluating for commit|New commits)"
{job="comin", host="homelab-<host>"} |~ "(?i)(switch|activat|error)"
```
