# DNS single point of failure: hosts resolving only via Tailscale MagicDNS

The PBS host resolves **exclusively through `100.100.100.100`** — Tailscale
MagicDNS. When `tailscaled` restarts, hiccups, or the node falls out of the
tailnet, **every** lookup on that host fails, including the one that reaches
Cloudflare R2.

**This sits under the backups.** `r2-store` is `backend type=s3` pointing at
Cloudflare R2. PBS resolves that endpoint through the same resolver as everything
else. If MagicDNS is unavailable at 03:00, the nightly job cannot reach its
storage — the same failure that ate three months of notification mail, just with
consequences.

## How it surfaced (2026-08-01)

Chasing why PBS notifications never arrived
([`pbs-verify-failures.md`](./pbs-verify-failures.md)), the postfix queue held
deferred mail with:

```
Host or domain name not found. Name service error for name=mozart409.com type=MX: Host not found, try again
```

`Host not found, try again` is a **temporary** failure (SERVFAIL/timeout), not
NXDOMAIN. And the records are fine — checked the same day:

```
mozart409.com.  300  IN  MX  10 mail.protonmail.ch.
mozart409.com.  300  IN  MX  20 mailsec.protonmail.ch.
;; SERVER: 100.100.100.100#53
```

So the record always existed and resolution is **intermittent**. The queued
failures are dated Jul 30 and Aug 1. A resolver that is periodically unavailable
fits exactly; a DNS misconfiguration does not.

**Live facts (verified 2026-08-01):**

| Fact | Value |
| --- | --- |
| PBS host | `pbs`, **192.168.2.112** (VMID 180 — the VMID is not the IP) |
| PBS resolver | **`100.100.100.100`** (Tailscale MagicDNS) — sole nameserver observed |
| MX lookup today | Works, 35 ms, Proton records |
| Failure signature | `Host not found, try again` — temporary, in postfix's deferred queue |
| Repo DNS host | `dns` @ **192.168.2.145** (`hosts/dns/configuration.nix`), tailnet `homelab-dns` |
| Blast radius | Unknown — only PBS has been checked |

## Status — not started (2026-08-01)

Found while diagnosing notification delivery. The mail path is now out of the
picture (`mail-to-root` disabled, notifications moved to a webhook), so nothing
is actively broken. **The R2 dependency is the reason this is worth doing
anyway.**

---

## Phase 1 — Establish the blast radius

- [ ] **1.1 Confirm PBS's resolver config.** `100.100.100.100` was observed as
      the answering server; confirm whether it is the *only* entry.
      ```bash
      cat /etc/resolv.conf
      tailscale status | head -3
      resolvectl status 2>/dev/null | grep -A3 'DNS Servers'
      ```
- [ ] **1.2 Check the rest of the fleet.** The NixOS hosts are repo-managed and
      may already have sane resolvers; PBS is a hand-built Debian VM and is not
      in this repo. Establish which hosts depend on MagicDNS alone.
      ```bash
      just colmena-exec -- 'cat /etc/resolv.conf'   # or per-host ssh
      ```
- [ ] **1.3 Check whether the tailnet has global nameservers set.** In the
      Tailscale admin console → DNS. If MagicDNS has upstream resolvers
      configured it degrades better, but it still dies with `tailscaled`.
- [ ] **1.4 Correlate.** Did anything restart Tailscale on Jul 30 / Aug 1?
      `journalctl -u tailscaled --since '2026-07-29'` on PBS. Confirms the
      mechanism rather than assuming it. See [[reinstalled-host-tailscale-reapproval]]
      — tailnet membership has bitten this homelab before.

## Phase 2 — Give PBS a resolver that survives Tailscale

Options, best first:

- **`tailscale set --accept-dns=false` + explicit resolvers.** Point PBS at the
  repo's DNS host (`192.168.2.145`) with a public fallback. Survives `tailscaled`
  being dead entirely, which is the actual failure mode.
  - Cost: `*.ts.net` names stop resolving on PBS. Check nothing depends on them —
    the datastore uses Cloudflare's public endpoint, so R2 is unaffected.
- **Tailscale admin console → global nameservers.** Simpler, no host change, but
  still routes every query through `tailscaled`. Mitigates upstream outages, not
  the SPOF.
- **Both.** Explicit resolvers on PBS, global nameservers for hosts that genuinely
  need MagicDNS.

- [ ] **2.1** Decide per the above.
- [ ] **2.2** Apply on PBS first — it is the one with backups behind it.
- [ ] **2.3** Verify: `dig MX mozart409.com`, `dig <r2-endpoint>`, then stop
      `tailscaled` and repeat. **Both must still resolve with Tailscale down** —
      that is the whole point.
- [ ] **2.4** Roll out to any other host Phase 1 flags.

## Verification

- `dig` for both an external name and the R2 endpoint succeeds **while
  `tailscaled` is stopped**.
- A backup run completes with Tailscale down (or at least, DNS resolution does).
- No `Host not found, try again` recurrences in any queue or log.

## Risks

- **Disabling `accept-dns` breaks `*.ts.net` resolution on that host.** Audit
  first. On PBS specifically, nothing obvious depends on it — but the MCP server
  config in `hosts/mcp_vm/configuration.nix` points at
  `https://pbs.dropbear-butterfly.ts.net/`, so the *dependency runs the other
  way* and is unaffected by PBS's own resolver.
- **This is latent, not urgent.** Nothing is broken today. The temptation is to
  skip it — the reason not to is that the failure mode is a silent 03:00 backup
  failure, and until [`pbs-verify-failures.md`](./pbs-verify-failures.md)'s
  notification work landed, there was no channel that would have told you.
- **Do not "fix" this by editing `/etc/resolv.conf` directly.** Tailscale and
  `resolvconf` rewrite it. Change it at the layer that owns it.

## Related

- [`pbs-verify-failures.md`](./pbs-verify-failures.md) — where this was found;
  the notification work that now makes such a failure visible.
- [[reinstalled-host-tailscale-reapproval]] — prior art on tailnet membership
  silently breaking name resolution in this homelab.
