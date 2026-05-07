{
  config,
  lib,
  pkgs,
  ...
}: {
  # Attic server token for admin operations
  age.secrets.attic-server-token = {
    file = ../../../secrets/attic-server-token.age;
    owner = "atticd";
    group = "atticd";
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

  # Ensure atticd data directories exist
  systemd.tmpfiles.rules = [
    "d /var/lib/atticd 0750 atticd atticd -"
    "d /var/lib/atticd/storage 0750 atticd atticd -"
  ];
}
