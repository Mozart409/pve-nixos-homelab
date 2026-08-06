# Nebula on NixOS — Lighthouse & Client Deployment Guide

Status: **research complete** — not yet implemented.
Branch: `feat/nebula-research`
Researched: 2026-08-06

Facts in this document were verified against two ground truths:

- **Upstream Nebula** docs ([nebula.defined.net/docs](https://nebula.defined.net/docs/)),
  the [slackhq/nebula](https://github.com/slackhq/nebula) README, example config, and
  CHANGELOG. Latest upstream release: **v1.11.0** (2026-07-23).
- **This repo's pinned nixpkgs** — ships `nebula` **1.10.3** and the
  `services.nebula` NixOS module whose source was read in full
  (`nixos/modules/services/networking/nebula.nix`). Option behavior documented
  below matches *that* source, not guesswork.

---

## 1. What Nebula is (and why, given we already run Tailscale)

Nebula is a mutually authenticated, peer-to-peer, layer-3 overlay network built
on the Noise Protocol Framework. Certificates assert each node's overlay IP,
name, and group memberships; those groups drive per-host firewall rules. It was
built by Slack and ran 50,000+ production hosts there.

| | Tailscale (current) | Nebula |
|---|---|---|
| Control plane | Tailscale SaaS | **You** — your CA + your lighthouses |
| Identity | SSO/OIDC user → device | CA-signed cert: name, overlay IP, groups |
| NAT traversal | Coordination + DERP relays | Lighthouse-assisted UDP hole-punch; self-hosted relays for hard NAT |
| ACLs | Hosted HuJSON ACLs | YAML group firewall on each host |
| DNS | MagicDNS | None built-in (optional lighthouse DNS); we already run unbound |
| Availability | Mesh degrades if Tailscale control plane has issues | Once peers discover each other, traffic flows with no control plane dependency |

Both can coexist on the same host (different tun devices, different CIDRs). The
natural homelab role for Nebula: a **self-hosted infrastructure mesh** whose
trust chain we own end-to-end, independent of any SaaS — complementing (or
long-term replacing parts of) the Tailscale overlay.

## 2. Architecture

### Roles

- **Lighthouse** — the discovery node. It tracks every host's underlay addresses
  and answers "where is host X?" queries. It is the *only* node whose address
  must be stable (static public IP or stable DNS name), because "you can't
  discover the discovery service": before a host has talked to a lighthouse, its
  static host map is its only source of addresses. A lighthouse is still a full
  Nebula node — it holds a host cert, can carry overlay traffic, and can double
  as a relay. Cheap to run: a $5 VPS class machine is plenty.
- **Node / client** — everything else (servers, laptops, phones). Reports its
  local interface addresses to all lighthouses every `lighthouse.interval`
  seconds (default 10 s; example configs use 60).
- **Relay** (v1.6+, still marked experimental upstream) — forwards traffic
  between two peers that cannot punch through their NATs (e.g. symmetric NAT).
  Opt-in on both sides: the relay sets `am_relay: true`, the client lists the
  relay's Nebula IP in `relay.relays`. Payloads stay end-to-end Noise-encrypted;
  the relay holds no A↔B session keys. No relay-chaining ("you cannot relay to
  a relay"). Any host with a publicly reachable UDP port can be one — commonly
  the lighthouse itself.

### NAT traversal (`punchy`)

The lighthouse learns a NAT'd host's public IP:port by observing the source of
its report packets. When A handshakes with B, the lighthouse signals B, and B
emits empty packets toward A to open B's NAT mapping. Two knobs matter:

- `punchy.punch: true` — periodically re-send empty packets so NAT/firewall
  mappings don't expire. Recommended everywhere.
- `punchy.respond: true` — the callee handshakes *back*; the escape hatch when
  one side is behind symmetric NAT. If even that fails → deploy a relay.

### Addressing & ports

- You choose one overlay CIDR (e.g. `10.42.0.0/16`). **Each host's overlay IP is
  baked into its certificate at signing time** — the tun address comes from the
  cert, not the config file.
- Underlay transport: **UDP, default port 4242**. Lighthouses and relays must
  use a *fixed* port; roaming nodes should use port `0` (ephemeral).
- Default MTU 1300 — safe for internet paths.
- v1.10 added IPv6 / multiple overlay IPs via a v2 cert format (new CAs already
  default to v2).

## 3. The NixOS module — verified option reference

Source read: `nixos/modules/services/networking/nebula.nix` in this repo's
pinned nixpkgs. The module manages **named networks** under
`services.nebula.networks.<name>` and does **not** manage certificates — you
supply `ca` / `cert` / `key` paths (agenix in our case; see §7).

### Options (from module source)

| Option | Type / default | Notes |
|---|---|---|
| `enable` | bool, `true` | per-network switch |
| `package` | package, `pkgs.nebula` | pinned nixpkgs: **1.10.3**; builds both `bin/nebula` and `bin/nebula-cert` |
| `ca` | path | CA trust bundle (PEM; may contain multiple CAs during rotation) |
| `cert` | path | this host's signed cert |
| `key` | path or nonEmptyStr | this host's private key |
| `isLighthouse` | bool, `false` | → `lighthouse.am_lighthouse` |
| `isRelay` | bool, `false` | → `relay.am_relay` (`use_relays` forced `true`) |
| `lighthouses` | listOf str, `[]` | **Nebula IPs** of lighthouses, *not* underlay IPs. Must be empty on lighthouses |
| `relays` | listOf str, `[]` | Nebula IPs of relays allowed to relay traffic *to* this node |
| `staticHostMap` | attrsOf (listOf str), `{}` | `"<nebula-ip>" = [ "<underlay-ip-or-dns>:<port>" ]` |
| `listen.host` | str, `"0.0.0.0"` | |
| `listen.port` | nullOr port, `null` | `null` → **4242 if lighthouse/relay, else 0** (ephemeral) |
| `tun.disable` | bool, `false` | lighthouse can run without tun/root |
| `tun.device` | nullOr str, `null` | defaults to `nebula.<networkName>` |
| `lighthouse.dns.{enable,host,port}` | false / `localhost` / 5353 | optional lighthouse DNS server |
| `firewall.{inbound,outbound}` | listOf attrs, `[]` | Nebula's own group firewall (default-deny; **empty list = allow nothing**) |
| `settings` | freeform YAML attrs | merged **over** everything above — escape hatch for `punchy`, `logging`, `stats`, `tun.mtu`, `pki.disconnect_invalid`, … |
| `enableReload` | bool, `false` | SIGHUP reload instead of restart on config change — see §9 for semantics |

### What the module generates (verified)

- **Config file**: `pki`/`static_host_map`/`lighthouse`/`relay`/`listen`/`tun`/
  `firewall` from the options above, deep-merged with `settings`. Rendered as
  YAML via `pkgs.formats.yaml`.
  - Default (`stateVersion` < 25.11, `enableReload = false`): config lives at a
    **nix-store path**, and the unit gets `restartTriggers` on it — any config
    change restarts the service (drops tunnels briefly).
  - `enableReload = true` **or** `stateVersion` ≥ 25.11: config is linked to
    `/etc/nebula/<name>.yml` (mode `0440`, owned by the service user) and
    changes trigger `systemctl reload` (SIGHUP) instead.
  - ⚠️ **This repo sets `system.stateVersion = "25.05"`** (`modules/common.nix`),
    so without `enableReload` we get store-path config + restarts. That's fine —
    restarts are safe, reloads are an optimization (§9 lists what's reloadable).
- **systemd unit** `nebula@<name>.service`: `Type=notify`, `Restart=always`
  (`StartLimitIntervalSec=0` so it retries forever), runs **before sshd**, and
  is heavily sandboxed (`NoNewPrivileges`, `ProtectSystem=true`,
  `ProtectHome`, `DeviceAllow=/dev/net/tun`, caps limited to `CAP_NET_ADMIN` +
  maybe `CAP_NET_BIND_SERVICE`, …).
- **Service user**: a dedicated system user/group named **`nebula-<name>`**
  (e.g. network `homelab` → user `nebula-homelab`). Every file Nebula reads —
  config, ca.crt, host.crt, **host.key** — must be readable by that user. This
  drives the agenix wiring in §7.
- **NixOS firewall**: the resolved listen port is added to
  `networking.firewall.allowedUDPPorts` automatically. You do *not* open 4242
  yourself.
- A warning is emitted at eval time if a lighthouse/relay ends up on port 0.

### Minimal shapes

Lighthouse (network `homelab`, lighthouse at Nebula IP `10.42.0.1`):

```nix
services.nebula.networks.homelab = {
  enable = true;
  isLighthouse = true;
  ca = config.age.secrets.nebula-ca-crt.path;
  cert = config.age.secrets.nebula-lighthouse-crt.path;
  key = config.age.secrets.nebula-lighthouse-key.path;
  # lighthouses + staticHostMap stay EMPTY on a lighthouse —
  # every node reports to it; it discovers no one.
  firewall.inbound = [{ port = "any"; proto = "icmp"; host = "any"; }];
  firewall.outbound = [{ port = "any"; proto = "any"; host = "any"; }];
  settings = {
    punchy.punch = true;
    pki.disconnect_invalid = true;
  };
};
```

Client (any other host; lighthouse reachable at `203.0.113.10:4242`):

```nix
services.nebula.networks.homelab = {
  enable = true;
  ca = config.age.secrets.nebula-ca-crt.path;
  cert = config.age.secrets.nebula-crt.path;   # per-host cert
  key = config.age.secrets.nebula-key.path;    # per-host key
  lighthouses = [ "10.42.0.1" ];               # NEBULA IP, not the public one
  staticHostMap = { "10.42.0.1" = [ "203.0.113.10:4242" ]; };
  firewall.inbound = [
    { port = "any"; proto = "icmp"; host = "any"; }
    { port = "22";  proto = "tcp";  group = "ops"; }
  ];
  firewall.outbound = [{ port = "any"; proto = "any"; host = "any"; }];
  settings.punchy = { punch = true; respond = true; };
};
```

## 4. Planning the mesh (decisions to make before touching nix)

1. **Overlay CIDR.** Pick something that collides with nothing: not
   `192.168.2.0/24` (LAN), not Tailscale's `100.64.0.0/10`. Suggestion:
   `10.42.0.0/16`, lighthouse at `10.42.0.1`, homelab hosts in `10.42.1.0/24`,
   laptops/roamers in `10.42.2.0/24` — room to grow, human-readable.
2. **Lighthouse placement — the one real architectural decision.** A lighthouse
   needs an address every node can always reach on a fixed UDP port:
   - **Option A: small external VPS** (upstream's recommendation). Public IP,
     open UDP 4242 in the provider firewall, done. Works for roamers anywhere,
     independent of the homelab's WAN/link. Costs a few €/month.
   - **Option B: an existing always-on homelab VM + port-forward** UDP 4242 on
     the router to it, referenced by stable DynDNS name. Works, including for
     external roamers, but couples mesh discovery to the home WAN and router
     config. VMs reboot/move; the forward must track it.
   - **Option C: LAN-only lighthouse** (e.g. on `dns`/`ca`). Fine if the mesh is
     *only* for LAN VMs — but then it adds little over the LAN itself.
   A lighthouse can also be a **relay** (`isRelay = true`) — recommended, so
   hard-NAT peers have a fallback from day one.
3. **Groups → firewall policy.** Groups are cert claims; firewall rules match on
   them. Sketch the policy *before* signing certs, e.g.:
   - `servers` — all homelab VMs
   - `ops` — machines allowed to SSH into everything (laptops, `development`)
   - `monitoring` — allowed to scrape metrics ports (the `otel` host)
   - `web` — hosts serving HTTP(S) to the mesh
   `groups:` (list) in a rule means AND — the peer cert must carry *all* listed
   groups.
4. **Which hosts join.** Any host that should be reachable when Tailscale is
   down or that should never depend on a third-party control plane.

## 5. PKI: CA and host certificates

`nebula-cert` ships **inside `pkgs.nebula`** (`bin/nebula-cert`) — no extra
package needed. Grab it ad-hoc with `nix shell nixpkgs#nebula`.

### Create the CA (once, offline machine)

```bash
mkdir -p ~/nebula-ca && cd ~/nebula-ca
nebula-cert ca -name "homelab" -duration 43800h   # ~5y; default is only 8760h (1y!)
# → ca.crt (public) + ca.key (CROWN JEWEL)
```

- `ca.key` never goes on *any* node — not even the lighthouse. Keep it on your
  workstation (or offline); consider `-encrypt` (AES-256-GCM + Argon2id) for
  at-rest protection.
- Choose the CA duration deliberately: host certs default to *CA expiry − 1 s*,
  so a 1-year CA means re-signing **every host** within a year.
- Optional guardrails: `-groups` / `-networks` / `-unsafe-networks` constrain
  what certs signed by this CA may claim.

### Sign host certs

Per host, two workflows:

**A. Simple (CA machine generates the keypair):**

```bash
nebula-cert sign -name "lighthouse1" -ip "10.42.0.1/16" -groups "servers,lighthouses"
nebula-cert sign -name "dns"         -ip "10.42.1.5/16" -groups "servers"
nebula-cert sign -name "laptop"      -ip "10.42.2.10/16" -groups "ops"
# → <name>.crt + <name>.key per host
```

**B. Private key never leaves the device (preferred for real deployments):**

```bash
# on the device:
nebula-cert keygen -out-key dns.key -out-pub dns.pub
# copy dns.pub to the CA machine, then:
nebula-cert sign -in-pub dns.pub -name "dns" -ip "10.42.1.5/16" -groups "servers"
# → dns.crt only; dns.key never crossed the network
```

### Inspect & verify

```bash
nebula-cert print  -path dns.crt            # name, IPs, groups, validity, fingerprint
nebula-cert verify -ca ca.crt -crt dns.crt  # signature + expiry check
```

### In this repo

Certs/keys become **agenix secrets** (§7). The CA itself should *not* live in
the repo — `ca.key` stays offline; only `ca.crt` (public) is distributed to
every host. Practical approach: keep the CA in a local, non-committed directory
on the admin workstation and treat it like the step-ca root.

## 6. Deploying the lighthouse on NixOS

Assuming Option A (VPS) or B (homelab VM + router forward): the NixOS side is
identical, only the underlay address in clients' `staticHostMap` differs.

As a repo module, e.g. `modules/nebula-lighthouse.nix` (or a dedicated host):

```nix
{ config, ... }: {
  age.secrets.nebula-ca-crt = {
    file = ../secrets/nebula-ca-crt.age;
    owner = "nebula-homelab";
    group = "nebula-homelab";
    mode = "0440";
  };
  age.secrets.nebula-lighthouse-crt = {
    file = ../secrets/nebula-lighthouse-crt.age;
    owner = "nebula-homelab";
    group = "nebula-homelab";
    mode = "0440";
  };
  age.secrets.nebula-lighthouse-key = {
    file = ../secrets/nebula-lighthouse-key.age;
    owner = "nebula-homelab";
    group = "nebula-homelab";
    mode = "0400";
  };

  services.nebula.networks.homelab = {
    enable = true;
    isLighthouse = true;
    isRelay = true;               # double as relay for hard-NAT peers
    ca = config.age.secrets.nebula-ca-crt.path;
    cert = config.age.secrets.nebula-lighthouse-crt.path;
    key = config.age.secrets.nebula-lighthouse-key.path;
    firewall.inbound = [
      { port = "any"; proto = "icmp"; host = "any"; }
      # { port = "53"; proto = "udp"; group = "any"; }  # only if lighthouse DNS enabled
    ];
    firewall.outbound = [{ port = "any"; proto = "any"; host = "any"; }];
    settings = {
      punchy.punch = true;
      pki.disconnect_invalid = true;   # drop tunnels when peer certs go stale
      logging.level = "info";
    };
  };

  # ensure secrets exist before nebula starts
  systemd.services."nebula@homelab" = {
    after = [ "agenix.service" ];
    requires = [ "agenix.service" ];
  };
}
```

Notes:

- The module resolves `listen.port` to **4242** automatically for
  lighthouse/relay and opens it in the NixOS firewall. On a VPS you *also* open
  UDP 4242 in the provider's security group; on Option B you add the router
  port-forward. The underlay firewall is the part nix cannot declare.
- Owner strings **must match the module's service user** (`nebula-<network>` —
  here `nebula-homelab`). Get the network name and the owner string out of sync
  and Nebula fails with a permission error on the key.
- `tun.disable = true` is an optional hardening for a lighthouse that never
  carries overlay traffic (no tun device, no `CAP_NET_ADMIN`). Leave it `false`
  if the lighthouse should be reachable *on* the mesh (e.g. to ping it) or act
  as relay.
- Optional lighthouse DNS (`lighthouse.dns.enable = true`) exists, but we
  already run unbound on `dns` — registering Nebula IPs as additional
  `local-data` A/PTR records there fits this repo better than a second DNS.

## 7. Deploying clients on NixOS

A shared module `modules/nebula.nix` (mirroring `modules/tailscale.nix`),
imported by every host that joins:

```nix
{ config, ... }: {
  age.secrets.nebula-ca-crt = {
    file = ../secrets/nebula-ca-crt.age;
    owner = "nebula-homelab"; group = "nebula-homelab"; mode = "0440";
  };
  age.secrets.nebula-crt = {
    file = ../secrets/nebula-dns-crt.age; # per-host, see secrets.nix wiring below
    owner = "nebula-homelab"; group = "nebula-homelab"; mode = "0440";
  };
  age.secrets.nebula-key = {
    file = ../secrets/nebula-dns-key.age;
    owner = "nebula-homelab"; group = "nebula-homelab"; mode = "0400";
  };

  services.nebula.networks.homelab = {
    enable = true;
    ca = config.age.secrets.nebula-ca-crt.path;
    cert = config.age.secrets.nebula-crt.path;
    key = config.age.secrets.nebula-key.path;
    lighthouses = [ "10.42.0.1" ];
    staticHostMap = { "10.42.0.1" = [ "203.0.113.10:4242" ]; }; # lighthouse underlay addr
    firewall.inbound = [
      { port = "any"; proto = "icmp"; host = "any"; }
      { port = "22"; proto = "tcp"; group = "ops"; }
      { port = "9100"; proto = "tcp"; group = "monitoring"; }  # node-exporter via mesh
    ];
    firewall.outbound = [{ port = "any"; proto = "any"; host = "any"; }];
    settings.punchy = { punch = true; respond = true; };
  };

  systemd.services."nebula@homelab" = {
    after = [ "agenix.service" ];
    requires = [ "agenix.service" ];
  };
}
```

> **Hostname caveat:** `networking.hostName` in this repo is usually the
> `homelab-<name>` form (e.g. `homelab-dns`). Either name the secret files to
> match and interpolate `config.networking.hostName` into `file =`, or add a
> small per-host option (`homelab.nebula.nodeName = "dns"`). Decide during
> implementation — the cert's `-name`, the agenix filename, and the nix must
> line up.

**Per-host wiring in `secrets/secrets.nix`** — one cert + one key secret per
host, encrypted only to that host + admins; `ca.crt` to all members:

```nix
"nebula-ca-crt.age".publicKeys = [amadeus amadeusAge] ++ nebulaMembers;
"nebula-dns-crt.age".publicKeys = [amadeus amadeusAge hostDns];
"nebula-dns-key.age".publicKeys = [amadeus amadeusAge hostDns];
```

**Workflow per new host** (follows the repo's agenix discipline — `agenix`
runs from inside `secrets/`, see AGENTS.md §6):

```bash
# 1. CA machine: sign the host cert (IP from your addressing plan)
nebula-cert sign -name "dns" -ip "10.42.1.5/16" -groups "servers"

# 2. encrypt each artifact to its recipients — from inside secrets/!
cd secrets
agenix -e nebula-dns-crt.age    # paste dns.crt
agenix -e nebula-dns-key.age    # paste dns.key
agenix -e nebula-ca-crt.age     # paste ca.crt (once, shared)

# 3. add the entries to secrets/secrets.nix (shown above), then
just reencrypt                  # only needed when recipients change

# 4. import modules/nebula.nix in the host, then
just colmena-apply-host dns
```

Notes:

- **Port 0 on clients is correct.** Non-lighthouse nodes get an ephemeral
  listen port by default (module resolves `null` → 0), and no firewall port is
  opened — hole punching + `punchy` handle inbound. Servers that expect *direct*
  inbound dials can set `listen.port = 4242` explicitly.
- `settings.stats` can expose Prometheus metrics
  (`stats = { type = "prometheus"; listen = "127.0.0.1:9810"; path = "/metrics"; }`)
  — a natural scrape job for `hosts/otel/configuration.nix` once rolled out.
- Roaming laptops (future, non-NixOS hosts too): keep `listen.port = 0`,
  `punchy.punch` on; the same cert workflow applies (mobile apps take the YAML
  + certs pasted in).

## 8. Firewall design with groups

Nebula's firewall is per-host, default-deny, allow-rules only — this is
*separate from* the NixOS firewall and evaluates overlay traffic only. Rule
match (since v1.9): `port AND proto AND (ca constraints) AND (host OR group OR
groups OR cidr) AND local_cidr`.

A sane starting policy:

| Direction | Rule | Purpose |
|---|---|---|
| inbound (every host) | `icmp / any / any` | ping for debugging — cheap and invaluable |
| inbound (servers) | `tcp/22 group=ops` | SSH only from operator machines |
| inbound (servers) | `tcp/9100 group=monitoring` | node-exporter scraped via mesh |
| inbound (web hosts) | `tcp/80,443 group=servers` | service traffic inside the mesh |
| outbound (every host) | `any/any/any` | permissive; tighten later if desired |

Tighten outbound per-host only after the mesh is stable — asymmetric
permissiveness (open out, closed in) breaks handshakes' expectations and makes
NAT punching harder to debug.

## 9. Verification & troubleshooting

```bash
systemctl status nebula@homelab
journalctl -u nebula@homelab -f
ip addr show nebula.homelab                       # tun device, cert IP attached
ping 10.42.0.1                                    # from a client to the lighthouse
nebula-cert print -path /run/agenix/nebula-crt    # validity dates, groups, IP
sudo tcpdump -ni ens18 udp port 4242              # handshakes/punches on the wire
```

Healthy startup: "Firewall rule added", "Main HostMap created", "Nebula
interface is active", then handshake messages with the lighthouse. While
debugging you can raise `settings.logging.level = "debug"` — turn it back off
afterwards (noisy, CPU-heavy, can log untrusted data).

Common failure modes:

1. **Cert/clock problems** — expired CA or host cert, or clock skew (certs have
   NotBefore/NotAfter). Check with `nebula-cert print`; keep NTP sane.
2. **Underlay firewall** — UDP 4242 not reachable at the lighthouse (cloud SG /
   router forward missing). tcpdump both ends: packets leaving A but never
   arriving at B ⇒ underlay.
3. **The two classic config mistakes** — `lighthouses` containing the
   lighthouse's *routable* IP instead of its **Nebula IP**; and a non-empty
   `lighthouses` list on the lighthouse itself. The module can't save you from
   either.
4. **Empty Nebula firewall** — `firewall.inbound`/`outbound` default to `[]`
   (deny all). Tunnels up but "nothing works" ⇒ no matching allow rule.
5. **agenix/permission mismatch** — key not readable by `nebula-<network>` ⇒
   service fails at startup. Check `owner`/`group` on the secret (§6/§7).
6. **Symmetric NAT** — enable `punchy.respond`; if still broken, point the
   client's `relays` at the lighthouse-relay.
7. **Reload semantics** — SIGHUP reloads PKI material without dropping tunnels,
   but a changed **cert IP needs a full restart**. With this repo's
   `stateVersion = "25.05"` and `enableReload = false`, colmena restarts the
   unit on config change anyway — predictable and safe.

## 10. Operations

### Adding a host later

Sign cert → encrypt crt/key via agenix (recipients: that host + admins) →
register in `secrets/secrets.nix` → import `modules/nebula.nix` →
`just colmena-apply-host <host>`. No lighthouse restart needed; lighthouses
learn about new hosts dynamically. If you run lighthouse **DNS** or unbound
`local-data` records for mesh names, add the A/PTR record in
`hosts/dns/configuration.nix`.

### CA rotation (no downtime)

Plan months before CA expiry (`nebula-cert print -path ca.crt` shows it):

1. Create the new CA (same name/CIDR/group constraints).
2. Append the new CA PEM to the `ca.crt` bundle distributed to every host;
   deploy. Nebula trusts both CAs now (`pki.disconnect_invalid` already on).
3. Re-sign every host cert with identical name/IP/groups against the new CA;
   distribute + deploy (restart or SIGHUP).
4. Remove the old CA from the bundle; deploy.

### Compromise response

- Host key compromised: re-sign that host, distribute, and add the old cert's
  **fingerprint** to `pki.blocklist` on every host (via `settings.pki.blocklist`
  — it is *not* propagated by lighthouses, config management must push it).
- CA compromised: full rotation, immediately.
- agenix makes redeploys cheap — rotate by re-encrypting new material and
  `colmena apply`.

### Version notes (upgrade watchlist)

- Pinned nixpkgs ships **1.10.3**. Upstream **1.11.0** (2026-07-23) is not in
  the pin yet; when the flake bumps past it, mind its breaking changes: logging
  switched to slog (upper-case `level=INFO`, reworded messages — check any Loki
  parsing), and `firewall.inbound_action`/`outbound_action` semantics were
  corrected (they were previously swapped). We don't set `reject` actions, so
  the second one is informational only.
- v1.10 (already in our pin): v2 cert format default for new CAs;
  `default_local_cidr_any` now defaults false — only relevant if we ever use
  `unsafe_routes` (avoid unless a device truly can't run Nebula).

## 11. Repo integration checklist (when implementing)

Following AGENTS.md §5, per host that joins the mesh:

1. `hosts/<hostname>/configuration.nix` imports `modules/nebula.nix` (lighthouse
   host imports `modules/nebula-lighthouse.nix` instead).
2. `secrets/secrets.nix`: host key already present as a recipient (it is, for
   every colmena host) + the three new `.age` entries; `just reencrypt`.
3. agenix files created **from inside `secrets/`** (`cd secrets && agenix -e …`).
4. DNS (optional): mesh-name A/PTR records in `hosts/dns/configuration.nix`.
5. Prometheus (optional): nebula stats scrape job in
   `hosts/otel/configuration.nix` with `labels.instance` set.
6. Gates: `just fmt`, `just colmena-build-host <host>` for one consumer (the
   flake-check caveat in AGENTS.md §3 applies), then `colmena apply`.
7. The lighthouse host additionally needs its **underlay-side opening** (VPS
   security group or router port-forward) — outside nix's reach.
8. New lighthouse/relay host = full new-host checklist (tofu VM, DNS, otel,
   flake registration) *plus* the above.

## 12. Open decisions for this homelab

| Question | Options | Lean |
|---|---|---|
| Lighthouse placement | A: VPS · B: homelab VM + router forward · C: LAN-only | **A** if roamers matter; **B** if LAN-mesh-only and budget-averse |
| Overlay CIDR | any non-colliding block | `10.42.0.0/16` |
| Lighthouse = relay? | recommended | yes |
| CA lifetime | ≥ 2–5 y (host certs inherit) | 5 y |
| CA storage | offline workstation dir / encrypted | offline, `-encrypt` optional |
| DNS for mesh names | unbound `local-data` vs lighthouse DNS | unbound (already ours) |
| Relationship to Tailscale | coexist / migrate | coexist; decide later with data |
| Cert distribution | simple sign vs on-device keygen | simple sign initially (homelab trust domain), keygen workflow documented for later |

## References

- Docs: [intro](https://nebula.defined.net/docs/) · [quick-start](https://nebula.defined.net/docs/guides/quick-start/) · [host discovery](https://nebula.defined.net/docs/guides/host-discovery/) · config reference ([lighthouse](https://nebula.defined.net/docs/config/lighthouse/), [punchy](https://nebula.defined.net/docs/config/punchy/), [relay](https://nebula.defined.net/docs/config/relay/), [firewall](https://nebula.defined.net/docs/config/firewall/), [pki](https://nebula.defined.net/docs/config/pki/), [static-host-map](https://nebula.defined.net/docs/config/static-host-map/)) · [CA rotation](https://nebula.defined.net/docs/guides/rotating-certificate-authority/) · [sign with public keys](https://nebula.defined.net/docs/guides/sign-certificates-with-public-keys/) · [viewing logs](https://nebula.defined.net/docs/guides/viewing-nebula-logs/)
- Repo: [README](https://github.com/slackhq/nebula) · [example config.yml](https://github.com/slackhq/nebula/blob/master/examples/config.yml) · [CHANGELOG](https://github.com/slackhq/nebula/blob/master/CHANGELOG.md)
- NixOS module source: `nixos/modules/services/networking/nebula.nix` (pinned nixpkgs; read 2026-08-06)
- Comparison: [tailscale.com/compare/nebula](https://tailscale.com/compare/nebula)
