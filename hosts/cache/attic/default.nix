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

    # services.atticd.environmentFile is a single path, but the DB URL has to be
    # a second file so it can be rotated independently of the signing secret.
    # systemd applies EnvironmentFile entries in order, so both are loaded.
    EnvironmentFile = lib.mkForce [
      config.age.secrets.attic-server-token.path
      config.age.secrets.attic-db-url.path
    ];
  };

  # Attic server token for admin operations (the RS256 signing secret).
  age.secrets.attic-server-token = {
    file = ../../../secrets/attic-server-token.age;
    owner = "atticd";
    group = "atticd";
    mode = "0400";
  };

  # PostgreSQL connection URL, as an env-file line:
  #   ATTIC_SERVER_DATABASE_URL=postgresql://attic:<pw>@192.168.2.134/attic
  #
  # It lives in a secret rather than in `settings.database.url` below because
  # settings are rendered into a world-readable /nix/store TOML — a password
  # there would be readable by every user on this host. atticd reads this env
  # var and it takes precedence over the TOML.
  #
  # The password is the same value as attic-db-password.age on the database
  # host; rotating it means re-encrypting both, exactly like the pg-mcp-*-url
  # secrets on the mcp host.
  age.secrets.attic-db-url = {
    file = ../../../secrets/attic-db-url.age;
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

      # Database: PostgreSQL on the `database` host (192.168.2.134), NOT the
      # module default of a local SQLite file.
      #
      # SQLite could not carry this workload. Every pushed path is its own
      # transaction and SQLite allows a single writer, so attic's default 5
      # parallel upload jobs serialised behind each other on the 2-HDD zfs_pool
      # (~78 IOPS shared cluster-wide). Even 64-byte paths failed, with
      # `Connection pool timed out` and `(code: 5) database is locked`.
      # `synchronous=NORMAL` would have cut the per-commit fsync cost, but sqlx
      # 0.9 rejects pragmas as connection-URL parameters (`unknown query
      # parameter journal_mode`) and `synchronous` is per-connection state that
      # cannot be set externally — so there was no way to reach it from config.
      #
      # Postgres removes the single-writer limit outright, and its WAL group
      # commit folds many small transactions into far fewer fsyncs, which is the
      # cost that actually hurt here. It does not raise the pool's IOPS ceiling
      # — pushes are still bounded by the disks — but they stop *failing*.
      #
      # `database.url` must be ABSENT from the generated TOML, which is why this
      # is an mkForce of the whole `database` attrset rather than simply not
      # setting the key.
      #
      # attic declares the field as `#[serde(default =
      # "load_database_url_from_env")]`: a TOML value always WINS, and
      # ATTIC_SERVER_DATABASE_URL is consulted only when the key is missing. So
      # any placeholder here silently defeats attic-db-url.age. Merely omitting
      # it is not enough either — the NixOS module supplies
      # `database.url = lib.mkDefault "sqlite:///var/lib/atticd/server.db"`,
      # so leaving it unset quietly restores local SQLite (which is exactly what
      # happened on the first attempt at this migration).
      #
      # With the attrset forced empty, the runtime URL comes from
      # attic-db-url.age and attic panics with an explicit message if that env
      # var is ever missing — it cannot fail silently back to SQLite.
      #
      # The build-time config check still passes: the module exports a throwaway
      # ATTIC_SERVER_DATABASE_URL="sqlite://:memory:" just for it.
      database = lib.mkForce {};
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
    sqlite # reading the pre-Postgres server.db (kept for the keypair migration)
    postgresql # psql: this host's database is now remote, on the database host
  ];
}
