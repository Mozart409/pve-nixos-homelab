{
  config,
  lib,
  pkgs,
  ...
}: let
  # Data directory for uptime-forge
  dataDir = "/var/lib/uptime-forge";
  postgresDataDir = "${dataDir}/postgres";
  forgeConfigDir = "${dataDir}/config";
in {
  # Enable Podman
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Create directories and config files
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${postgresDataDir} 0755 root root -"
    "d ${forgeConfigDir} 0755 root root -"
  ];

  # PostgreSQL configuration file
  environment.etc."uptime-forge/postgresql.conf" = {
    mode = "0644";
    source = ./postgres/postgresql.conf;
  };

  # PostgreSQL init scripts
  environment.etc."uptime-forge/initdb/001-timescaledb.sql" = {
    mode = "0644";
    source = ./postgres/initdb/001-timescaledb.sql;
  };

  # Forge configuration
  environment.etc."uptime-forge/forge.toml" = {
    mode = "0644";
    source = ./forge.toml;
  };

  # Load secrets via agenix
  age.secrets.uptime-forge-db-password = {
    file = ../../../secrets/uptime-forge-db-password.age;
    mode = "0400";
  };

  # Create a script that reads the secret and sets up environment
  systemd.services.uptime-forge-db-env = {
    description = "Generate uptime-forge database environment file";
    wantedBy = ["podman-uptime-forge-db.service"];
    before = ["podman-uptime-forge-db.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/uptime-forge
      DB_PASSWORD=$(cat ${config.age.secrets.uptime-forge-db-password.path})
      cat > /run/uptime-forge/db.env << EOF
      POSTGRES_USER=uptime
      POSTGRES_PASSWORD=$DB_PASSWORD
      POSTGRES_DB=uptime_forge
      EOF
      chmod 600 /run/uptime-forge/db.env
    '';
  };

  systemd.services.uptime-forge-app-env = {
    description = "Generate uptime-forge app environment file";
    wantedBy = ["podman-uptime-forge.service"];
    before = ["podman-uptime-forge.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/uptime-forge
      DB_PASSWORD=$(cat ${config.age.secrets.uptime-forge-db-password.path})
      cat > /run/uptime-forge/app.env << EOF
      DATABASE_URL=postgres://uptime:$DB_PASSWORD@uptime-forge-db:5432/uptime_forge
      EOF
      chmod 600 /run/uptime-forge/app.env
    '';
  };

  # OCI Containers
  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      uptime-forge-db = {
        image = "timescale/timescaledb:latest-pg16";
        autoStart = true;
        ports = ["5444:5432"];
        volumes = [
          "uptime_forge_db:/var/lib/postgresql/data"
          "/etc/uptime-forge/postgresql.conf:/etc/postgresql/postgresql.conf:ro"
          "/etc/uptime-forge/initdb:/docker-entrypoint-initdb.d:ro"
        ];
        environmentFiles = ["/run/uptime-forge/db.env"];
        cmd = ["postgres" "-c" "config_file=/etc/postgresql/postgresql.conf"];
        extraOptions = [
          "--network=uptime-forge-net"
          "--health-cmd=pg_isready -U uptime -d uptime_forge"
          "--health-interval=10s"
          "--health-timeout=5s"
          "--health-retries=5"
        ];
      };

      uptime-forge = {
        image = "ghcr.io/mozart409/uptime-forge:v0.2.5";
        autoStart = true;
        ports = ["3000:3000"];
        volumes = [
          "/etc/uptime-forge/forge.toml:/app/forge.toml:ro"
        ];
        environmentFiles = ["/run/uptime-forge/app.env"];
        dependsOn = ["uptime-forge-db"];
        extraOptions = [
          "--network=uptime-forge-net"
          "--health-cmd=wget --no-verbose --tries=1 --spider http://localhost:3000/health"
          "--health-interval=30s"
          "--health-timeout=3s"
          "--health-start-period=5s"
          "--health-retries=3"
        ];
      };
    };
  };

  # Create the podman network before containers start
  systemd.services.podman-network-uptime-forge = {
    description = "Create podman network for uptime-forge";
    wantedBy = ["podman-uptime-forge-db.service" "podman-uptime-forge.service"];
    before = ["podman-uptime-forge-db.service" "podman-uptime-forge.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists uptime-forge-net || \
        ${pkgs.podman}/bin/podman network create uptime-forge-net
    '';
  };

  # Ensure proper service ordering
  systemd.services.podman-uptime-forge = {
    after = ["podman-uptime-forge-db.service" "podman-network-uptime-forge.service" "uptime-forge-app-env.service"];
    requires = ["podman-network-uptime-forge.service" "uptime-forge-app-env.service"];
  };

  systemd.services.podman-uptime-forge-db = {
    after = ["podman-network-uptime-forge.service" "uptime-forge-db-env.service"];
    requires = ["podman-network-uptime-forge.service" "uptime-forge-db-env.service"];
  };
}
