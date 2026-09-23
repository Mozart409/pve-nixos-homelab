# User Context

The user runs a Proxmox-based homelab of NixOS VMs, managed declaratively from a
single flake (`pve-nixos-homelab`) with Colmena, Disko, agenix and OpenTofu.
Everything that should persist lives in that repo; a file hand-written onto a
running host is gone at the next deploy.

- **Network:** `192.168.2.0/24`. Internal names resolve as
  `<host>.homelab.local` and `<host>.homelab.internal`, served by the `dns` host
  and carrying step-ca TLS certificates.
- **Tailnet:** `dropbear-butterfly.ts.net`. MagicDNS names do **not** resolve
  between homelab VMs — use the `.homelab.local` / `.homelab.internal` names for
  anything host-to-host.
- **Forge:** Forgejo at `forgejo.homelab.local:2222`, which is canonical. The
  GitHub remote is a manual mirror a human pushes; never push to it.
- **Identity:** Pocket ID is the homelab's OIDC provider.
- **Hosts include:** dns, ca, database, otel (Prometheus/Grafana/Loki/Tempo),
  containers, mcp (the axon gateway), forgejo, woodpecker, jellyfin, unifi,
  development, and this one (hermes).

This machine, `hermes` (192.168.2.155), exists to run agents. The user reaches
it over ssh/mosh on the tailnet, through the Moshi app on their phone, and
through the web dashboard at `hermes-dashboard.homelab.internal`.

The user commits frequently and prefers single-line conventional-commit
subjects with no body.
