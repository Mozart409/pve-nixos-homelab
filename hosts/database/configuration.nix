{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
  ];

  networking.hostName = "homelab-database";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.134";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  # PostgreSQL configuration
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;

    settings = {
      # Performance tuning (adjust based on available RAM)
      shared_buffers = "256MB";
      effective_cache_size = "1GB";
      maintenance_work_mem = "64MB";
      work_mem = "4MB";
      max_connections = 100;

      # Enable query logging (optional)
      log_statement = "all";
      log_duration = true;
    };

    # Enable TCP/IP connections
    enableTCPIP = true;

    # Authentication configuration
    authentication = pkgs.lib.mkOverride 10 ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             all                                     peer
      host    all             all             127.0.0.1/32            scram-sha-256
      host    all             all             ::1/128                 scram-sha-256
      host    all             all             10.0.0.0/8              scram-sha-256
      host    all             all             192.168.0.0/16          scram-sha-256
    '';

    # Initial databases
    ensureDatabases = ["appdb" "appuser"];

    # Initial users
    ensureUsers = [
      {
        name = "appuser";
        ensureDBOwnership = true;
      }
    ];
  };

  # Backup configuration
  services.postgresqlBackup = {
    enable = true;
    databases = ["appdb"];
    location = "/var/backup/postgresql";
    startAt = "03:00";
    compression = "zstd";
  };

  services.prometheus = {
    exporters.postgres = {
      enable = true;
      runAsLocalSuperUser = true;
    };
    exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
    };
  };

  # Prometheus exporter

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      5432 # PostgreSQL
      9100 # Node exporter
      9187 # Postgres exporter
    ];
  };

  # Additional database management tools
  environment.systemPackages = with pkgs; [
    postgresql_18
    pgcli
    pg_top
    pg_activity
  ];

  # Create backup directory and ensure postgres data directory is NoCoW (for Btrfs)
  systemd.tmpfiles.rules = [
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/lib/postgresql 0750 postgres postgres - +C"
  ];
}
