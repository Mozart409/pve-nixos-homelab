{
  config,
  lib,
  pkgs,
  ...
}: {
  # Garage RPC secret for cluster communication
  age.secrets.garage-rpc-secret = {
    file = ../../../secrets/garage-rpc-secret.age;
    owner = "garage";
    group = "garage";
  };

  # Garage S3-compatible object storage
  services.garage = {
    enable = true;
    package = pkgs.garage;

    settings = {
      metadata_dir = "/var/lib/garage/meta";
      data_dir = "/var/lib/garage/data";

      db_engine = "lmdb";

      replication_factor = 1;

      rpc_bind_addr = "[::]:3901";
      rpc_public_addr = "192.168.2.175:3901";

      s3_api = {
        s3_region = "garage";
        api_bind_addr = "[::]:3900";
        root_domain = ".s3.homelab.local";
      };

      admin = {
        api_bind_addr = "[::]:3902";
      };
    };

    environmentFile = config.age.secrets.garage-rpc-secret.path;
  };

  # Ship the garage journal to the central Loki. The fluent-bit shipper itself
  # is enabled in ../attic/default.nix (modules/loki-logs.nix); the units list
  # merges across modules, so garage's entry lives here with the rest of its
  # config. Logs land in Loki under job="garage".
  services.loki-logs.units = [
    {
      unit = "garage.service";
      job = "garage";
    }
  ];

  # Ensure garage data directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/garage 0750 garage garage -"
    "d /var/lib/garage/meta 0750 garage garage -"
    "d /var/lib/garage/data 0750 garage garage -"
  ];

  # Create garage user/group before service starts
  users.users.garage = {
    isSystemUser = true;
    group = "garage";
    home = "/var/lib/garage";
  };
  users.groups.garage = {};
}
