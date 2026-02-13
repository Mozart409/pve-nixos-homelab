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

  # Template files for environment variables
  dbEnvTemplate = pkgs.writeText "db-env-template" ''
    POSTGRES_USER=uptime
    POSTGRES_PASSWORD=__DB_PASSWORD__
    POSTGRES_DB=uptime_forge
  '';

  appEnvTemplate = pkgs.writeText "app-env-template" ''
    DATABASE_URL=postgres://uptime:__DB_PASSWORD__@uptime-forge-db:5432/uptime_forge
  '';

  # Script to generate db.env
  generateDbEnv = pkgs.writeShellScript "generate-db-env" ''
    mkdir -p /run/uptime-forge
    DB_PASSWORD=$(cat ${config.age.secrets.uptime-forge-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${dbEnvTemplate} > /run/uptime-forge/db.env
    chmod 600 /run/uptime-forge/db.env
  '';

  # Script to generate app.env
  generateAppEnv = pkgs.writeShellScript "generate-app-env" ''
    mkdir -p /run/uptime-forge
    DB_PASSWORD=$(cat ${config.age.secrets.uptime-forge-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${appEnvTemplate} > /run/uptime-forge/app.env
    chmod 600 /run/uptime-forge/app.env
  '';
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
    mode = "0440";
    group = "postgres-exporter";
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
        image = "ghcr.io/mozart409/uptime-forge:v0.2.6";
        autoStart = true;
        ports = ["3000:3000"];
        volumes = [
          "/etc/uptime-forge/forge.toml:/app/forge.toml:ro"
        ];
        environmentFiles = ["/run/uptime-forge/app.env"];
        dependsOn = ["uptime-forge-db"];
        extraOptions = [
          "--network=uptime-forge-net"
          "--health-cmd=curl -fsS http://localhost:3000/health"
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

  # Configure container services with ExecStartPre to generate env files
  systemd.services.podman-uptime-forge-db = {
    after = ["podman-network-uptime-forge.service"];
    requires = ["podman-network-uptime-forge.service"];
    serviceConfig = {
      ExecStartPre = ["${generateDbEnv}"];
    };
  };

  systemd.services.podman-uptime-forge = {
    after = ["podman-uptime-forge-db.service" "podman-network-uptime-forge.service"];
    requires = ["podman-network-uptime-forge.service"];
    serviceConfig = {
      ExecStartPre = ["${generateAppEnv}"];
    };
  };

  # Custom postgres exporter service (not using services.prometheus.exporters.postgres)
  # because we need to inject the password from agenix at runtime
  users.users.postgres-exporter = {
    isSystemUser = true;
    group = "postgres-exporter";
    description = "Prometheus postgres exporter service user";
  };
  users.groups.postgres-exporter = {};

  systemd.services.prometheus-postgres-exporter = {
    description = "Prometheus PostgreSQL Exporter";
    after = ["network.target" "podman-uptime-forge-db.service"];
    wants = ["podman-uptime-forge-db.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "postgres-exporter";
      Group = "postgres-exporter";
      ExecStart = let
        wrapper = pkgs.writeShellScript "postgres-exporter-wrapper" ''
          export DATA_SOURCE_NAME="postgresql://uptime:$(cat ${config.age.secrets.uptime-forge-db-password.path})@localhost:5444/uptime_forge?sslmode=disable"
          exec ${pkgs.prometheus-postgres-exporter}/bin/postgres_exporter \
            --web.listen-address=0.0.0.0:9187 \
            --web.telemetry-path=/metrics
        '';
      in "${wrapper}";
      Restart = "on-failure";
      RestartSec = 5;
      PrivateTmp = true;
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };
}
