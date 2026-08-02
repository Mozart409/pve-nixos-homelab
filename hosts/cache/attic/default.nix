{
  config,
  lib,
  pkgs,
  ...
}: {
  # Attic server token for admin operations (the RS256 signing secret).
  #
  # services.atticd runs with DynamicUser = true, so although its unit says
  # User=atticd that account is transient — systemd materialises it at service
  # start and it does NOT exist in /etc/passwd. Owning this secret by "atticd"
  # therefore fails activation outright with `chown: invalid user:
  # 'atticd:atticd'`, which is not recoverable at runtime.
  #
  # Grant access by group instead: a real group that the dynamic user joins via
  # SupplementaryGroups below. That keeps DynamicUser's isolation instead of
  # trading it away for a static account just to satisfy chown.
  age.secrets.attic-server-token = {
    file = ../../../secrets/attic-server-token.age;
    group = "atticd-secrets";
    mode = "0440";
  };

  users.groups.atticd-secrets = {};

  # Attic binary cache server
  services.atticd = {
    enable = true;

    environmentFile = config.age.secrets.attic-server-token.path;

    settings = {
      listen = "[::]:8080";

      # API endpoint configuration
      api-endpoint = "https://cache.homelab.local";

      # Use local storage (alternative: S3 via Garage)
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      # Chunking settings for deduplication
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };

      # Compression settings
      compression = {
        type = "zstd";
      };

      # Garbage collection settings
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "6 months";
      };

      # Database configuration (SQLite by default)
      database = {
        url = "sqlite:///var/lib/atticd/server.db?mode=rwc";
      };
    };
  };

  # Let the transient atticd user read the signing secret above.
  systemd.services.atticd.serviceConfig.SupplementaryGroups = ["atticd-secrets"];

  # NB: no systemd.tmpfiles rules for /var/lib/atticd. The unit sets
  # StateDirectory=atticd, and under DynamicUser systemd owns that path — real
  # state lives in /var/lib/private/atticd with /var/lib/atticd as a symlink to
  # it. Declaring `d /var/lib/atticd` would both fight that symlink and fail on
  # the same non-existent atticd user as the secret did. atticd creates its own
  # storage/ subdirectory beneath it.

  # `attic` (client) for cache administration — creating caches, minting push
  # tokens, reading the public signing key. `atticd-atticadm` ships with the
  # server and mints JWTs, but every cache-level operation goes through the
  # client against the HTTP API. sqlite3 is here for inspecting server.db, which
  # is otherwise unreadable on this host.
  environment.systemPackages = with pkgs; [
    attic-client
    sqlite
  ];
}
