{
  config,
  lib,
  pkgs,
  ...
}: {
  # hofvarpnir: the user's Rust fetch-and-store media app, migrated off the old
  # Rocky LXC (192.168.2.100) onto this host so it writes completed downloads
  # straight onto the tuned ZFS media pool — no NFS, no cross-host mount wall.
  # https://github.com/Mozart409/hofvarpnir
  #
  # Deployed as an OCI container (rootful podman, see modules/podman.nix), same
  # pattern as axon-gateway / romm. Postgres lives on homelab-database; media
  # lives under /media/hofvarpnir (bind-mounted at the container's downloads dir).
  # Public access is via hofvarpnir.homelab.local (Caddy vhost + step-ca TLS in
  # ./configuration.nix). The old tsbridge name keeps hitting the LXC until cutover.

  virtualisation.oci-containers.containers.hofvarpnir = {
    # Pin to the released tag for reproducibility — never :latest. Matches the tag
    # that was running on the LXC.
    image = "ghcr.io/mozart409/hofvarpnir:0.2.4";
    autoStart = true;

    # Container :3000 -> host 127.0.0.1:3000. Loopback only so it is reachable
    # solely via this host's Caddy (axon/romm pattern); no firewall change.
    # A publish IS required even for loopback — without it Caddy cannot reach the
    # container across the network namespace.
    ports = ["127.0.0.1:3000:3000"];

    # Run as jellyfin:jellyfin (999:999 on this host) so every file written under
    # /media/hofvarpnir is owned by the Jellyfin service and readable by it.
    user = "999:999";

    volumes = [
      # Completed + incomplete downloads land on the ZFS pool. tmpfiles already
      # creates /media/hofvarpnir 0755 jellyfin:jellyfin.
      "/media/hofvarpnir:/var/lib/hofvarpnir/downloads"
      # Host CA bundle (includes step-ca) so the container can verify TLS to
      # *.homelab.local over HTTPS (e.g. the Loki push endpoint). SSL_CERT_FILE
      # points native-tls/OpenSSL at it. If the binary is built against rustls it
      # ignores this and uses bundled webpki-roots (would not trust step-ca) — in
      # that case Loki log-push over HTTPS fails but the app + OTLP still work.
      "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
    ];

    environment = {
      # --- Server bind (MUST match the port published above) ----------------
      # App defaults to 127.0.0.1:8080; prod overrides to 0.0.0.0:3000 so the
      # podman port publish (127.0.0.1:3000 -> container 3000) actually reaches
      # the listener. HOST=0.0.0.0 = bind all interfaces *inside* the container's
      # netns (still only exposed on the host's loopback via the publish).
      HOST = "0.0.0.0";
      PORT = "3000";

      # --- App behaviour (verbatim from the LXC compose) --------------------
      MAX_CONCURRENT_DOWNLOADS = "1";
      DOWNLOAD_TIMEOUT_HOURS = "9";
      MAX_DOWNLOAD_ATTEMPTS = "2";
      RATE_LIMIT_DELAY_SECS = "600";
      RUST_LOG = "info,hofvarpnir=info,sqlx=warn";
      DEFAULT_OUTPUT_DIR = "/var/lib/hofvarpnir/downloads";
      API_BASE_URL = "https://hofvarpnir.homelab.local";

      # --- Observability ----------------------------------------------------
      # Rewritten from the LXC's homelab-otel.*.ts.net (MagicDNS does NOT resolve
      # between homelab VMs) to the step-ca *.homelab.local names on the otel host.
      METRICS_ENABLED = "true";
      LOKI_URL = "https://otel.homelab.local/loki"; # Caddy handle /loki* -> :3100
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel.homelab.local:4317"; # plain gRPC
      OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
      OTEL_SERVICE_NAME = "hofvarpnir";

      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";

      # --- OIDC (Pocket ID) -------------------------------------------------
      # Non-secret OIDC config lives here; OIDC_CLIENT_ID + OIDC_CLIENT_SECRET
      # come from the agenix env file below (the client is registered in the
      # Pocket ID admin UI, which mints those two values).
      #
      # Issuer = Pocket ID's ts.net name (same one romm uses from a container;
      # its cert is publicly trusted so discovery works over rustls or native-tls).
      # from_env() enables OIDC only when ISSUER + CLIENT_ID + CLIENT_SECRET are
      # all present. redirect_uri() ignores API_BASE_URL and uses ONLY
      # OIDC_REDIRECT_BASE_URL, so it must be set — the callback the app builds
      # (and the URL to register in Pocket ID) is:
      #   https://hofvarpnir.homelab.local/auth/oidc/callback
      # First OIDC login links to the existing user whose email matches the
      # Pocket ID email claim (get_user_by_email), preserving that account.
      OIDC_ISSUER = "https://pocketid.dropbear-butterfly.ts.net";
      OIDC_SCOPES = "openid,profile,email";
      OIDC_AUTO_PROVISION = "true";
      OIDC_REDIRECT_BASE_URL = "https://hofvarpnir.homelab.local";
    };

    # Secrets injected as root before podman launches:
    #   DATABASE_URL       — central Postgres (database.homelab.local, sslmode=disable)
    #   OIDC_CLIENT_ID     — from Pocket ID (not strictly secret, kept here for convenience)
    #   OIDC_CLIENT_SECRET — from Pocket ID (secret)
    environmentFiles = [config.age.secrets.hofvarpnir-env.path];
  };

  age.secrets.hofvarpnir-env = {
    file = ../../secrets/hofvarpnir-env.age;
    mode = "0400";
  };
}
