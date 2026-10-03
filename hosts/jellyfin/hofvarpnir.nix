{
  config,
  lib,
  pkgs,
  ...
}: let
  otelEnvFile = "/run/hofvarpnir/otel.env";
in {
  # hofvarpnir: the user's Rust fetch-and-store media app, migrated off the old
  # Rocky LXC (192.168.2.100) onto this host so it writes completed downloads
  # straight onto the tuned ZFS media pool — no NFS, no cross-host mount wall.
  # https://github.com/Mozart409/hofvarpnir
  #
  # Deployed as an OCI container (rootful podman, see modules/podman.nix), same
  # pattern as axon-gateway / romm. Postgres lives on homelab-database; media
  # lives under /media/hofvarpnir (bind-mounted at the container's downloads dir).
  # Public access is via hofvarpnir.homelab.internal (canonical) and
  # hofvarpnir.homelab.local (Caddy vhost + step-ca TLS in ./configuration.nix).
  # The old tsbridge name keeps hitting the LXC until cutover.

  virtualisation.oci-containers.containers.hofvarpnir = {
    # Pin to the released tag for reproducibility — never :latest. Matches the tag
    # that was running on the LXC.
    image = "ghcr.io/mozart409/hofvarpnir:0.15.0";
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
      # *.homelab.local, including the OTLP and Loki pushes to otel below.
      # Both exporters verify against the system store (reqwest 0.13 via
      # rustls-platform-verifier; reqwest 0.12 via native roots), which reads
      # SSL_CERT_FILE -- verified end to end in hofvarpnir's
      # tests/otel_export.rs against a private CA.
      "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      # yt-dlp's cache (JS-challenge/sigfunc solver state, etc.) lives under
      # $HOME/.cache — but the image bakes /home/hofvarpnir as 1000:1000 while
      # this container actually runs as 999:999 (jellyfin, for media ownership
      # parity above), so without an explicit mount here that directory is not
      # writable by the running UID and every yt-dlp call re-solves JS
      # challenges from scratch (PermissionError, compounding CPU cost).
      # tmpfiles creates /var/lib/hofvarpnir-cache 0755 jellyfin:jellyfin.
      "/var/lib/hofvarpnir-cache:/home/hofvarpnir/.cache"
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
      API_BASE_URL = "https://hofvarpnir.homelab.internal";

      # --- Observability ----------------------------------------------------
      # Rewritten from the LXC's homelab-otel.*.ts.net (MagicDNS does NOT resolve
      # between homelab VMs) to the step-ca *.homelab.local names on the otel host.
      METRICS_ENABLED = "true";
      # Both pipelines go through Caddy on otel's aggregate vhost, gated by the
      # fleet push token (headers rendered at container start, see preStart
      # below). The app appends the signal paths itself: "/v1/traces" for
      # OTLP/HTTP and "/loki/api/v1/push" for Loki -- exactly the two paths
      # that vhost forwards with the push token. OTLP/HTTP, not gRPC: Caddy
      # has no h2c upstream for the collector's 4317.
      LOKI_URL = "https://otel.homelab.local";
      OTEL_EXPORTER_OTLP_ENDPOINT = "https://otel.homelab.local";
      OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
      OTEL_SERVICE_NAME = "hofvarpnir";
      # Sampling is tunable without a release; unset means 100%. To cut Tempo
      # IO: OTEL_TRACES_SAMPLER = "parentbased_traceidratio" plus
      # OTEL_TRACES_SAMPLER_ARG = "0.1".

      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      # TLS to postgres (hosts/database has ssl = true). DATABASE_URL in
      # hofvarpnir-env.age says `database.homelab.local?sslmode=verify-full`;
      # sqlx takes the root cert from this libpq env var (its rustls build
      # would otherwise verify against bundled webpki roots, which do not
      # include step-ca) and the host CA bundle is mounted above.
      PGSSLROOTCERT = "/etc/ssl/certs/ca-certificates.crt";

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
      #   https://hofvarpnir.homelab.internal/auth/oidc/callback
      # First OIDC login links to the existing user whose email matches the
      # Pocket ID email claim (get_user_by_email), preserving that account.
      OIDC_ISSUER = "https://pocketid.dropbear-butterfly.ts.net";
      OIDC_SCOPES = "openid,profile,email";
      OIDC_AUTO_PROVISION = "true";
      OIDC_REDIRECT_BASE_URL = "https://hofvarpnir.homelab.internal";
    };

    # Secrets injected as root before podman launches:
    #   DATABASE_URL       — central Postgres (database.homelab.local, sslmode=verify-full);
    #                        embeds the hofvarpnir role password, so rotating
    #                        hofvarpnir-db-password.age means re-encrypting this too
    #   OIDC_CLIENT_ID     — from Pocket ID (not strictly secret, kept here for convenience)
    #   OIDC_CLIENT_SECRET — from Pocket ID (secret)
    #   OTEL_EXPORTER_OTLP_HEADERS, LOKI_HEADERS
    #                      — rendered from the fleet push token at start (below)
    environmentFiles = [
      config.age.secrets.hofvarpnir-env.path
      otelEnvFile
    ];
  };

  # Auth for the otel pushes, from the same fleet push token this host's
  # fluent-bit already uses (age.secrets.otel-push-token is declared by
  # modules/fluent-bit.nix, imported in ./configuration.nix). Rendered at
  # container start instead of copied into hofvarpnir-env.age, so a token
  # rotation needs one re-encryption, not two. Both vars share the OTLP
  # headers format: `key=value`, value percent-encoded -- so `%` and `,`
  # inside the token are escaped (a base64/hex token has neither).
  # /run/hofvarpnir is the RuntimeDirectory oci-containers already gives this
  # unit: recreated on every start before ExecStartPre and removed on stop, so
  # the rendered token (0600 root via the umask) never outlives the container.
  systemd.services.podman-hofvarpnir.preStart = lib.mkBefore ''
    token="$(< ${config.age.secrets.otel-push-token.path})"
    token="''${token//%/%25}"
    token="''${token//,/%2C}"
    (
      umask 077
      printf 'OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%%20%s\nLOKI_HEADERS=Authorization=Bearer%%20%s\n' \
        "$token" "$token" > ${otelEnvFile}
    )
  '';

  age.secrets.hofvarpnir-env = {
    file = ../../secrets/hofvarpnir-env.age;
    mode = "0400";
  };

  # The env file is read once at container start and lives at a stable
  # /run/agenix path, so a re-encrypted secret changes nothing in the unit and
  # colmena apply would keep the container running on the old DATABASE_URL.
  # The secret's .file is its store path, which changes on every re-encryption.
  # Same for the push token rendered into otelEnvFile.
  systemd.services.podman-hofvarpnir.restartTriggers = [
    config.age.secrets.hofvarpnir-env.file
    config.age.secrets.otel-push-token.file
  ];
}
