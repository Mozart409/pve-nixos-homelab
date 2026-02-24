{
  config,
  lib,
  pkgs,
  ...
}: let
  # Data directory for harbor
  dataDir = "/var/lib/harbor";

  # Template files for environment variables
  dbEnvTemplate = pkgs.writeText "harbor-db-env-template" ''
    POSTGRES_DB=registry
    POSTGRES_USER=harbor
    POSTGRES_PASSWORD=__DB_PASSWORD__
  '';

  coreEnvTemplate = pkgs.writeText "harbor-core-env-template" ''
    POSTGRESQL_HOST=harbor-db
    POSTGRESQL_PORT=5432
    POSTGRESQL_DATABASE=registry
    POSTGRESQL_USERNAME=harbor
    POSTGRESQL_PASSWORD=__DB_PASSWORD__
    REDIS_URL=redis://harbor-redis:6379
    REGISTRY_URL=http://harbor-registry:5000
    CORE_URL=http://harbor-core:8080
    HARBOR_ADMIN_PASSWORD=__ADMIN_PASSWORD__
    CORE_SECRET=__CORE_SECRET__
    JOBSERVICE_SECRET=__CORE_SECRET__
    _REDIS_URL_CORE=redis://harbor-redis:6379/0
  '';

  # Script to generate db.env
  generateDbEnv = pkgs.writeShellScript "generate-harbor-db-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${dbEnvTemplate} > /run/harbor/db.env
    chmod 600 /run/harbor/db.env
  '';

  # Script to generate core.env
  generateCoreEnv = pkgs.writeShellScript "generate-harbor-core-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ADMIN_PASSWORD=$(cat ${config.age.secrets.harbor-admin-password.path})
    CORE_SECRET=$(cat ${config.age.secrets.harbor-core-secret.path})
    ${pkgs.gnused}/bin/sed \
      -e "s/__DB_PASSWORD__/$DB_PASSWORD/" \
      -e "s/__ADMIN_PASSWORD__/$ADMIN_PASSWORD/" \
      -e "s/__CORE_SECRET__/$CORE_SECRET/" \
      ${coreEnvTemplate} > /run/harbor/core.env
    chmod 600 /run/harbor/core.env
  '';
in {
  # Create directories
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/registry 0755 root root -"
    "d ${dataDir}/database 0755 root root -"
  ];

  # Harbor configuration files
  environment.etc."harbor/registry.yml" = {
    mode = "0644";
    source = ./config/registry.yml;
  };

  environment.etc."harbor/core.conf" = {
    mode = "0644";
    source = ./config/core.conf;
  };

  # Load secrets via agenix
  age.secrets.harbor-db-password = {
    file = ../../../secrets/harbor-db-password.age;
    mode = "0440";
    group = "root";
  };

  age.secrets.harbor-admin-password = {
    file = ../../../secrets/harbor-admin-password.age;
    mode = "0440";
    group = "root";
  };

  age.secrets.harbor-core-secret = {
    file = ../../../secrets/harbor-core-secret.age;
    mode = "0440";
    group = "root";
  };

  # OCI Containers
  virtualisation.oci-containers.containers = {
    # Harbor PostgreSQL database
    harbor-db = {
      image = "postgres:13-alpine";
      autoStart = true;
      volumes = [
        "harbor_db:/var/lib/postgresql/data"
      ];
      environmentFiles = ["/run/harbor/db.env"];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=pg_isready -U harbor -d registry"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=5"
      ];
    };

    # Harbor Redis
    harbor-redis = {
      image = "redis:7-alpine";
      autoStart = true;
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=redis-cli ping"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=5"
      ];
    };

    # Harbor Registry
    harbor-registry = {
      image = "goharbor/registry-photon:v2.11.2";
      autoStart = true;
      ports = ["5000:5000"];
      volumes = [
        "harbor_registry:/var/lib/registry"
        "/etc/harbor/registry.yml:/etc/registry/config.yml:ro"
      ];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=curl -fsS http://localhost:5000/v2/ || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
    };

    # Harbor Core (main API service)
    harbor-core = {
      image = "goharbor/harbor-core:v2.11.2";
      autoStart = true;
      ports = ["8080:8080"];
      volumes = [
        "/etc/harbor/core.conf:/etc/core/app.conf:ro"
      ];
      environmentFiles = ["/run/harbor/core.env"];
      dependsOn = ["harbor-db" "harbor-redis" "harbor-registry"];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=curl -fsS http://localhost:8080/api/v2.0/ping || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
    };

    # Harbor Portal (UI)
    harbor-portal = {
      image = "goharbor/harbor-portal:v2.11.2";
      autoStart = true;
      ports = ["8081:8080"];
      dependsOn = ["harbor-core"];
      extraOptions = [
        "--network=harbor-net"
      ];
    };
  };

  # Create the podman network before containers start
  systemd.services.podman-network-harbor = {
    description = "Create podman network for harbor";
    wantedBy = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-portal.service"
    ];
    before = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-portal.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists harbor-net || \
        ${pkgs.podman}/bin/podman network create harbor-net
    '';
  };

  # Configure container services with ExecStartPre to generate env files
  systemd.services.podman-harbor-db = {
    after = ["podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig = {
      ExecStartPre = ["${generateDbEnv}"];
    };
  };

  systemd.services.podman-harbor-redis = {
    after = ["podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };

  systemd.services.podman-harbor-registry = {
    after = ["podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };

  systemd.services.podman-harbor-core = {
    after = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-network-harbor.service"
    ];
    requires = ["podman-network-harbor.service"];
    serviceConfig = {
      ExecStartPre = ["${generateCoreEnv}"];
    };
  };

  systemd.services.podman-harbor-portal = {
    after = ["podman-harbor-core.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };
}
