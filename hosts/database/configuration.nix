{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
  ];

  networking.hostName = "database";

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
      local   all             all                                     trust
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
      host    all             all             10.0.0.0/8              md5
      host    all             all             192.168.0.0/16          md5
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
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22 # SSH
      5432 # PostgreSQL
    ];
  };

  # Additional database management tools
  environment.systemPackages = with pkgs; [
    postgresql_18
    pgcli
    pg_top
  ];

  # Create backup directory
  systemd.tmpfiles.rules = [
    "d /var/backup/postgresql 0700 postgres postgres -"
  ];
}
