{
  config,
  lib,
  pkgs,
  ...
}: {
  # pbsmcp-server: Proxmox Backup Server MCP server. Exposes PBS datastore /
  # snapshot / GC / node-status data to MCP clients over streamable-HTTP.
  #
  # Deployed as an OCI container (rootful podman, see modules/podman.nix) from the
  # private homelab Harbor (the `mcp-servers` project is public, so no pull auth).
  # We reference Harbor via harbor.homelab.local (NOT the *.ts.net MagicDNS name,
  # which does not resolve between homelab VMs) — that host's step-ca TLS is
  # trusted here via modules/step-ca-trust.nix. Image is digest-pinned for
  # reproducibility (never :latest).
  #
  # The MCP endpoint is served at http://<bind>/mcp. The container binds
  # 0.0.0.0:8080 internally and we publish it on 127.0.0.1:8093 so only this
  # host's Caddy proxies to it. Public access is via pbs-mcp.homelab.local (Caddy
  # vhost + step-ca TLS in ../configuration.nix), and it is registered as a
  # backend in ../axon-gateway/default.nix.

  virtualisation.oci-containers.containers = {
    pbsmcp-server = {
      # Digest-pinned pull from the homelab Harbor (mcp-servers project).
      image = "harbor.homelab.local/mcp-servers/pbsmcp-server@sha256:1745f86342249594de66f5d6c6e6c68483c9e1056beb10f34df6fe5ef1ce41c4";
      autoStart = true;

      # Container :8080 -> host 127.0.0.1:8093. Bound to loopback so it is only
      # reachable via Caddy on this host (mirrors axon-gateway/searxng); no
      # firewall change needed.
      ports = ["127.0.0.1:8093:8080"];

      environment = {
        # Bind on all container interfaces so the published port reaches it
        # (binding 127.0.0.1 inside the container would be unreachable from the
        # host port mapping). The MCP endpoint is then at /mcp.
        PBS_BIND = "0.0.0.0:8080";
        # DNS-rebinding protection: only accept these Host headers. Caddy
        # forwards the original host (pbs-mcp.homelab.local); the loopback names
        # cover direct/healthcheck access.
        PBS_ALLOWED_HOSTS = "pbs-mcp.homelab.local,localhost,127.0.0.1";
      };

      # Secrets (PBS_HOST, PBS_API_KEY, and optionally PBS_NODE / PBS_INSECURE)
      # are injected from the agenix env file. systemd reads it as root before
      # podman starts the container. See secrets/pbsmcp-env.age — fill it with:
      #   PBS_HOST=https://<pbs-host>:8007
      #   PBS_API_KEY=monitor@pbs!mcp:xxxxxxxx-...
      #   # PBS_INSECURE=1   # if PBS uses a self-signed cert
      environmentFiles = [config.age.secrets.pbsmcp-env.path];

      extraOptions = [
        # Give in-flight MCP sessions time to drain on stop.
        "--stop-timeout=30"
      ];
    };
  };

  # pbsmcp-server environment secret. Container runs under rootful podman;
  # systemd reads EnvironmentFile as root before launching, so 0400 is enough.
  age.secrets.pbsmcp-env = {
    file = ../../../secrets/pbsmcp-env.age;
    mode = "0400";
  };
}
