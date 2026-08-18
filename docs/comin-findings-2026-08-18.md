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

## Host Status (2026-08-18)

| Host | comin.service | Last Deployed Commit | Notes |
|------|---------------|---------------------|-------|
| dns | active | `e25e70a` (feat: reduce loki log retention) | evaluating `32bc81d` |
| containers | active | — | responsive, comin running |
| fleet | active | — | responsive, comin running |
| mcp | active* | — | SSH intermittently unreachable |
| otel | active* | — | SSH intermittently unreachable |
| cache | active* | — | SSH intermittently unreachable |

\* Confirmed active during initial check; SSH timeouts on subsequent polls
are likely due to nix evaluation load on the host.

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
