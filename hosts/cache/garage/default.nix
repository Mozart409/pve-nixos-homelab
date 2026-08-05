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

  # Garage is currently UNUSED -- attic keeps its store on local disk and no
  # S3 clients exist -- and with its layout never assigned it spams a
  # bootstrap/discovery WARN burst into the journal every ~60s (surfaced by
  # the loki-logs shipper below: ~1200 lines/15m of "Ring not yet ready").
  #
  # Disabled but NOT removed: dropping the boot trigger stops garage from
  # running, while the unit file, the garage CLI, the user, the state dirs and
  # this config all stay in place. Changing wantedBy does NOT stop an
  # already-running unit, so after deploying run once:
  #   sudo systemctl stop garage
  # Re-enable by deleting this block (it comes back at the next boot, or
  # immediately with `systemctl start garage`). While disabled, Caddy's /s3/*
  # route proxies to a dead port and returns 502 -- acceptable, nothing uses it.
  systemd.services.garage.wantedBy = lib.mkForce [];

  # Ship the garage journal to the central Loki. The fluent-bit shipper itself
  # is enabled in ../attic/default.nix (modules/loki-logs.nix); the units list
  # merges across modules, so garage's entry lives here with the rest of its
  # config. Logs land in Loki under job="garage". Idles to zero while garage
  # is disabled below, and resumes by itself when garage is re-enabled.
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
