{
  config,
  lib,
  pkgs,
  ...
}: let
  # axon-gateway: high-performance MCP gateway that aggregates multiple MCP
  # servers behind a single endpoint. https://github.com/Mozart409/axon-gateway
  #
  # Lives on the mcp host since 2026-09-14 (it ran on `containers` before).
  # The move is a security fix, not a tidy-up: the MCP servers it aggregates
  # bind loopback on this host, and putting the gateway on the same box is
  # what lets them stay there. Before, each backend had a public Caddy vhost
  # with no authentication so the gateway could reach it from another VM --
  # which meant anyone on the LAN could reach it too and skip the gateway's
  # bearer token altogether.
  #
  # Deployed as an OCI container (rootful podman, modules/podman.nix) because
  # the published image bundles the Rust binary with its static UI assets.
  # It runs with HOST networking: that is the only way a container can dial
  # 127.0.0.1:<port> services on the host, and it is why `bind` below is a
  # loopback address rather than 0.0.0.0 -- with host networking there is no
  # port mapping to hide behind, whatever the container binds is what the
  # host listens on. Only Caddy (vhosts below) is meant to talk to it.
  gatewayPort = 8100;

  # Declarative gateway config. Secrets are NOT inlined here — they are referenced
  # as ${VAR} placeholders and resolved by axon at startup from the environment
  # file below. Missing referenced vars are a hard startup error, so every ${VAR}
  # used here MUST be present in secrets/axon-gateway-env.age.
  #
  # Pulled into a `let` binding (rather than staying inline as `environment.etc`'s
  # `.text`) solely so its content can be hashed below into the restart nonce —
  # see `CONFIG_HASH` in the container's `environment`.
  #
  # Backend ports are the `bind` values in ../configuration.nix's
  # services.homelab-mcp.servers -- keep the two in step.
  configText = ''
    [gateway]
    bind = "127.0.0.1:${toString gatewayPort}"
    base_url = "https://axon.homelab.local"
    # Bearer token clients must present to use the gateway.
    auth_token = "''${AXON_GATEWAY_TOKEN}"
    rate_limit_per_minute = 1000

    # --- Backends (the MCP servers being aggregated) -------------------------
    # All on this host's loopback; plain HTTP is fine, nothing leaves the box.

    [[backends]]
    name = "hamcp"
    url = "http://127.0.0.1:8084/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pbs"
    url = "http://127.0.0.1:8080/mcp"
    transport = "http"
    enabled = true

    # Postgres: one backend per database. pgmcp holds a single connection pool
    # from one URL and no tool takes a database argument, so each database needs
    # its own server instance (see ../configuration.nix). The backend name
    # prefixes the tool names — pgappdb_run_query, pgforgejo_run_query, …
    # (pguptime, for the uptime-forge TimescaleDB, was retired 2026-09-12.)
    [[backends]]
    name = "pgappdb"
    url = "http://127.0.0.1:8085/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pgterraform"
    url = "http://127.0.0.1:8087/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pgforgejo"
    url = "http://127.0.0.1:8088/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pgromm"
    url = "http://127.0.0.1:8089/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pghofvarpnir"
    url = "http://127.0.0.1:8090/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "prom"
    url = "http://127.0.0.1:8082/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "loki"
    url = "http://127.0.0.1:8083/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "woodpecker"
    url = "http://127.0.0.1:8091/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "alertmanager"
    url = "http://127.0.0.1:8086/mcp"
    transport = "http"
    enabled = true
  '';

  gatewayVhost = ''
    handle {
      # 127.0.0.1, never "localhost": Caddy resolves proxy upstreams through
      # the system resolver, and a `localhost` lookup here has timed out
      # against unbound ("dial tcp: lookup localhost: i/o timeout" -> 502 or a
      # hung request). A literal IP is dialed directly, with no DNS at all.
      reverse_proxy http://127.0.0.1:${toString gatewayPort}
    }
  '';
in {
  environment.etc."axon-gateway/config.toml".text = configText;

  virtualisation.oci-containers.containers = {
    axon-gateway = {
      image = "ghcr.io/mozart409/axon-gateway:v0.3.2";
      autoStart = true;
      volumes = [
        "/etc/axon-gateway/config.toml:/app/config.toml:ro"
        # step-ca root for anything the gateway still dials over TLS (none of
        # the backends today, but base_url/health checks may).
        "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      ];
      cmd = ["/app/config.toml"];
      environment = {
        RUST_LOG = "info";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        # Restart nonce: podman's generated unit only changes when the
        # container's own definition does, so a config.toml edit alone used to
        # need a manual restart. Hashing the text into an env var makes the
        # unit change with it.
        CONFIG_HASH = builtins.hashString "sha256" configText;
      };
      environmentFiles = [config.age.secrets.axon-gateway-env.path];
      extraOptions = [
        "--network=host"
        "--health-cmd=wget -q --spider http://127.0.0.1:${toString gatewayPort}/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=10s"
        "--health-on-failure=kill"
        "--stop-timeout=30"
      ];
    };
  };

  # The MCP servers must be listening before the gateway probes them, or it
  # marks them dead until its next reconnect.
  systemd.services.podman-axon-gateway = {
    after = map (n: "${n}.service") (builtins.attrNames config.services.homelab-mcp.servers);
    wants = map (n: "${n}.service") (builtins.attrNames config.services.homelab-mcp.servers);
  };

  age.secrets.axon-gateway-env = {
    file = ../../../secrets/axon-gateway-env.age;
    mode = "0400";
  };

  services.caddy.virtualHosts = {
    # Tailscale hostname. Used to front hamcp directly; now the gateway.
    "homelab-mcp.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }
        ${gatewayVhost}
      '';
    };
    # axon.homelab.local moved here from the containers host on 2026-09-14;
    # every client (hermes, otel's alertmanager bridge, development, the
    # dashboard health check, prometheus) reaches it by that name, so for
    # them the move was a DNS change (hosts/dns/configuration.nix).
    "axon.homelab.local axon.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }
        ${gatewayVhost}
      '';
    };
  };
}
