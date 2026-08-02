{
  config,
  lib,
  pkgs,
  ...
}: {
  # Run atticd as a STATIC user instead of the upstream module's
  # DynamicUser = true.
  #
  # DynamicUser is meant for stateless units, and atticd is not one — it owns a
  # SQLite database and a content-addressed store under StateDirectory. systemd
  # allocates the UID from a transient range, and when that allocation moves the
  # service can no longer read data written under the previous UID. That is
  # exactly what happened here: state was written as uid 65534 while the service
  # came back up as uid 65312, and every upload failed with
  # `Storage error: Failed to read version file: Permission denied` because
  # storage/VERSION is mode 0600 owned by the old UID.
  #
  # A stable uid also makes the transient account real, so agenix can chown the
  # signing secret to it during activation (activation orders users before
  # secrets) rather than failing with `chown: invalid user: 'atticd:atticd'`.
  users.users.atticd = {
    isSystemUser = true;
    group = "atticd";
  };
  users.groups.atticd = {};

  systemd.services.atticd.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "atticd";
    Group = "atticd";
  };

  # Attic server token for admin operations (the RS256 signing secret).
  age.secrets.attic-server-token = {
    file = ../../../secrets/attic-server-token.age;
    owner = "atticd";
    group = "atticd";
    mode = "0400";
  };

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

  # NB: no systemd.tmpfiles rules for /var/lib/atticd. StateDirectory=atticd
  # already creates and owns that path, and atticd creates storage/ beneath it.
  # Declaring it again only risks fighting systemd over ownership — which is the
  # mixed-UID mess the static user above exists to prevent.
  #
  # One-time migration when switching off DynamicUser: state lived in
  # /var/lib/private/atticd with /var/lib/atticd as a symlink to it. Without
  # DynamicUser systemd wants /var/lib/atticd to be a real directory, so after
  # the first deploy of this change:
  #   sudo systemctl stop atticd
  #   sudo rm /var/lib/atticd                       # the symlink
  #   sudo mv /var/lib/private/atticd /var/lib/atticd
  #   sudo chown -R atticd:atticd /var/lib/atticd   # heals the orphaned UIDs
  #   sudo systemctl start atticd

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
