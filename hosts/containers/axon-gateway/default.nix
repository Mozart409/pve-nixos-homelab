{
  config,
  lib,
  pkgs,
  ...
}: {
  # axon-gateway: high-performance MCP gateway that aggregates multiple MCP
  # servers behind a single endpoint. https://github.com/Mozart409/axon-gateway
  #
  # Deployed as an OCI container (rootful podman, see modules/podman.nix) because
  # the published image already bundles the Rust binary together with the static
  # UI assets and Tailwind output.css. The container listens on :8080 internally;
  # we publish it on 127.0.0.1:8091 so only this host's Caddy proxies to it
  # (8080 is taken by AlbyHub). Public access is via axon.homelab.local (Caddy
  # vhost + step-ca TLS in ../configuration.nix).

  # Declarative gateway config. Secrets are NOT inlined here — they are referenced
  # as ${VAR} placeholders and resolved by axon at startup from the environment
  # file below. Missing referenced vars are a hard startup error, so every ${VAR}
  # used here MUST be present in secrets/axon-gateway-env.age.
  environment.etc."axon-gateway/config.toml".text = ''
    [gateway]
    bind = "0.0.0.0:8080"
    base_url = "https://axon.homelab.local"
    # Bearer token clients must present to use the gateway.
    auth_token = "''${AXON_GATEWAY_TOKEN}"
    rate_limit_per_minute = 1000

    # --- Backends (the MCP servers being aggregated) -------------------------
    # Service-to-service URLs use *.homelab.local (NOT Tailscale MagicDNS, which
    # does not resolve between homelab VMs). These carry step-ca TLS certs; the
    # container trusts them via the CA bundle mounted below + SSL_CERT_FILE.

    [[backends]]
    name = "hamcp"
    url = "https://mcp.homelab.local/mcp"
    transport = "http"
    enabled = true

    [[backends]]
    name = "pbs"
    url = "https://pbs-mcp.homelab.local/mcp"
    transport = "http"
    enabled = true

    # Example of a second backend — copy this block per MCP server you add.
    # [[backends]]
    # name = "secure-api"
    # url = "https://example.com/mcp"
    # transport = "http"
    # auth_token = "''${SECURE_API_TOKEN}"
    # enabled = true
  '';

  virtualisation.oci-containers.containers = {
    axon-gateway = {
      # Pin to a released tag for reproducibility — never :latest.
      image = "ghcr.io/mozart409/axon-gateway:v0.2.0";
      autoStart = true;

      # Container :8080 -> host 127.0.0.1:8091. Bound to loopback so it is only
      # reachable via Caddy on this host (mirrors searxng); no firewall change.
      ports = ["127.0.0.1:8091:8080"];

      volumes = [
        # Declarative config (read-only). Contains no secrets, only ${VAR} refs.
        "/etc/axon-gateway/config.toml:/app/config.toml:ro"
        # Host CA bundle (includes step-ca) so the container can verify TLS to
        # *.homelab.local backends. SSL_CERT_FILE points OpenSSL/native-tls at
        # it. If axon is built against rustls it ignores this — in that case
        # expose the backend over plain HTTP instead.
        "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      ];

      # The entrypoint is the binary; it takes the config path as its argument.
      cmd = ["/app/config.toml"];

      environment = {
        RUST_LOG = "info";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };

      # Secrets (AXON_GATEWAY_TOKEN, any per-backend tokens) are injected here.
      # systemd reads the file as root before podman starts the container.
      environmentFiles = [config.age.secrets.axon-gateway-env.path];

      extraOptions = [
        # wget was added to the runtime image in v0.1.8, so the compose-style
        # healthcheck works again (it was a no-op/broken on v0.1.7's Wolfi base).
        "--health-cmd=wget -q --spider http://localhost:8080/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=10s"
        # Give in-flight MCP sessions time to drain on stop.
        "--stop-timeout=30"
      ];
    };
  };

  # axon-gateway environment secret.
  # The container runs under rootful podman; systemd reads EnvironmentFile as
  # root before launching, so root-only (0400) access is sufficient.
  age.secrets.axon-gateway-env = {
    file = ../../../secrets/axon-gateway-env.age;
    mode = "0400";
  };
}
