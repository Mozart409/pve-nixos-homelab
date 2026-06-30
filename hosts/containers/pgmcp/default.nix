{
  config,
  lib,
  pkgs,
  ...
}: {
  # pgmcp-server: PostgreSQL MCP server. Exposes Postgres query/schema data to
  # MCP clients over streamable-HTTP.
  #
  # Deployed as an OCI container (rootful podman, see modules/podman.nix) from the
  # private homelab Harbor (the `mcp-servers` project is public, so no pull auth).
  # We reference Harbor via harbor.homelab.local (NOT the *.ts.net MagicDNS name,
  # which does not resolve between homelab VMs) — that host's step-ca TLS is
  # trusted here via modules/step-ca-trust.nix. Image is digest-pinned for
  # reproducibility (never :latest).
  #
  # The MCP endpoint is served at http://<bind>/mcp. The container binds
  # 0.0.0.0:8080 internally and we publish it on 127.0.0.1:8094 so only this
  # host's Caddy proxies to it. Public access is via pg-mcp.homelab.local (Caddy
  # vhost + step-ca TLS in ../configuration.nix), and it is registered as a
  # backend in ../axon-gateway/default.nix.

  virtualisation.oci-containers.containers = {
    pgmcp-server = {
      # Digest-pinned pull from the homelab Harbor (mcp-servers project), 0.2.4.
      image = "harbor.homelab.local/mcp-servers/pgmcp-server@sha256:56eea0aa8157bb6886b6b3809e95924620d569232ff43d88cd0bafd389f42f03";
      autoStart = true;

      # Container :8080 -> host 127.0.0.1:8094. Bound to loopback so it is only
      # reachable via Caddy on this host (mirrors pbsmcp/axon-gateway); no
      # firewall change needed.
      ports = ["127.0.0.1:8094:8080"];

      # Connection secret (PG_DATABASE_URL) is injected from the agenix env file.
      # systemd reads it as root before podman starts the container. See
      # secrets/pgmcp-env.age — fill it with:
      #   PG_DATABASE_URL=postgres://<user>:<pass>@<host>:5432/<db>
      environmentFiles = [config.age.secrets.pgmcp-env.path];

      extraOptions = [
        # Give in-flight MCP sessions time to drain on stop.
        "--stop-timeout=30"
      ];
    };
  };

  # pgmcp-server environment secret. Container runs under rootful podman;
  # systemd reads EnvironmentFile as root before launching, so 0400 is enough.
  age.secrets.pgmcp-env = {
    file = ../../../secrets/pgmcp-env.age;
    mode = "0400";
  };
}
