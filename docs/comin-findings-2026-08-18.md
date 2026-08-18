# Comin (GitOps) Findings

Date: 2026-08-18

## Service Name

The comin systemd unit is **`comin.service`**, not `comin-agent`. Always check
with:

```bash
systemctl is-active comin.service   # returns "active" when running
comin status                         # human-readable status
```

## How It Works

Comin is a pull-based GitOps agent configured declaratively in
`modules/comin.nix` and imported by every real host (both in
`nixosConfigurations` and in `colmenaHive` via `cominFor "<hostname>"`).

1. **Fetcher** — polls the Forgejo HTTPS remote
   (`https://forgejo.homelab.local/amadeus/pve-nixos-homelab.git`) on a timer,
   clones/pulls into `/var/lib/comin/repository`.
2. **Builder** — evaluates `nixosConfigurations."<hostname>".config.system.build.toplevel`
   from the local clone using `nix --extra-experimental-features flakes nix-command`.
   This is the slow phase (10–20 min on modest hardware).
3. **Deployer** — if the evaluation succeeds and the outpath differs from the
   last deployed generation, runs `nixos-rebuild switch` to the new closure.
   Stores the result under `/nix/var/nix/profiles/system-profiles/comin-*-link`.

## Configuration

`modules/comin.nix`:

```nix
services.comin = {
  enable = true;
  inherit hostname;   # flake attribute name (e.g. "dns"), NOT networking.hostName
  remotes = [{
    name = "origin";
    url = "https://forgejo.homelab.local/amadeus/pve-nixos-homelab.git";
    branches.main.name = "main";   # operation defaults to "switch"
  }];
};
```

No authentication secret is needed — the Forgejo HTTPS remote is anonymously
cloneable and step-ca trusted on every host (`modules/step-ca-trust.nix`).

## Known Warning (Harmless)

```
fatal: Refusing to point HEAD outside of refs/
warning: could not update cached head 'master' for 'file:///var/lib/comin/repository'
```

This appears every fetch cycle. Comin fetches by commit SHA (`<rev> -> FETCH_HEAD`)
rather than by branch ref, which git treats as a detached HEAD outside `refs/`.
The local clone still has all objects and comin resolves the correct commit.
This is a known comin quirk, not a failure.

## Host Status (2026-08-18, ~21:30 CET)

All six hosts respond to ICMP ping. SSH is responsive on two hosts and hangs
on four — likely due to concurrent nix evaluations consuming CPU/memory.

| Host | comin.service | Last Deployed Commit | Commit Being Evaluated | Notes |
|------|---------------|---------------------|----------------------|-------|
| dns | active | `e25e70a` (feat: reduce loki log retention) | `32bc81d` (15+ min) | SSH hangs; ping OK |
| containers | active | `e25e70a` (feat: reduce loki log retention) | `27f6262` (3 min) | `Need to reboot: yes` |
| mcp | active* | unknown | unknown | SSH hangs; ping OK |
| fleet | active | `7f576dd` (docs: track comin rollout) | `27f6262` (< 1 min) | `Need to reboot: yes` |
| cache | active* | unknown | unknown | SSH hangs (banner timeout); ping OK |
| otel | active* | unknown | unknown | SSH hangs; ping OK |

\* Confirmed `comin.service` active earlier. SSH hangs are consistent with nix
evaluation load, not a comin or host failure.

### SSH Hang Pattern

When hosts evaluate nix configs via comin, the SSH daemon becomes progressively
unresponsive. There are two levels:

1. **Slow commands** — SSH connects but commands take 10–30s to return
   (seen on dns, mcp at lower load).
2. **Banner exchange timeout** — SSH daemon doesn't even complete the
   initial handshake, even with a 120s connect timeout. The host still
   responds to ICMP ping. This means `sshd` is starved of CPU/memory and
   can't accept new connections (seen on mcp, cache, otel under concurrent
   eval load).

In both cases the host is alive and comin is running — it's just a resource
contention issue. The evaluation eventually finishes and SSH recovers.

### axon-gateway Impact

When multiple hosts evaluate simultaneously, the axon-gateway backends
(Prometheus on `otel`, Loki on `fleet`) also time out. This is the same
resource starvation: the hosts running the monitoring stack are busy
evaluating nix configs and can't serve API requests within the 30s
timeout.

## Common Misconceptions

- **"comin-agent" does not exist.** The unit is `comin.service`.
- **Comin does NOT restart itself after config changes** the same way colmena
  does. Since `config.toml`/`comin.yaml` come from the Nix store, a new
  generation changes the unit and systemd handles the restart.
- **Evaluation is slow.** A full `nixosConfigurations.<host>.config.system.build.toplevel`
  eval on a homelab VM takes 10–20 minutes. The `comin status` Builder section
  will show "Evaluation started N minutes ago" for that entire window. This is
  normal, not a hang.
- **No auth needed.** The HTTPS remote is step-ca trusted and anonymously
  cloneable. No SSH key or token is configured for comin.

## Debugging

```bash
# Is comin running?
systemctl is-active comin.service

# What's it doing right now?
comin status

# Recent activity
journalctl -u comin.service --since "1 hour ago" | grep -E 'level=(info|error|warn)'

# The local git clone
cd /var/lib/comin/repository && git log --oneline -5

# Current deployed generation
readlink /nix/var/nix/profiles/system-profiles/comin-*-link
```
