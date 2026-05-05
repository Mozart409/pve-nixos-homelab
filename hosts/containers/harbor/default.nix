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
    POSTGRESQL_SSLMODE=disable
    REDIS_URL=redis://harbor-redis:6379
    REGISTRY_URL=http://harbor-registry:5000
    CORE_URL=http://harbor-core:8080
    CORE_LOCAL_URL=http://127.0.0.1:8080
    HARBOR_ADMIN_PASSWORD=__ADMIN_PASSWORD__
    CORE_SECRET=__CORE_SECRET__
    JOBSERVICE_SECRET=__CORE_SECRET__
    _REDIS_URL_CORE=redis://harbor-redis:6379/0
    _REDIS_URL_REG=redis://harbor-redis:6379/1
    EXT_ENDPOINT=https://harbor.homelab.local
    CONFIG_PATH=/etc/core/app.conf
    LOG_LEVEL=info
    TOKEN_SERVICE_URL=http://harbor-core:8080/service/token
    REGISTRY_STORAGE_PROVIDER_NAME=filesystem
    WITH_TRIVY=true
    TRIVY_ADAPTER_URL=http://harbor-trivy:8080
    WITH_NOTARY=false
    CHART_REPOSITORY_URL=http://harbor-core:8080/chartrepo
    PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE=docker-hub,harbor,azure-acr,aws-ecr,google-gcr,quay,docker-registry,github-ghcr,jfrog-artifactory
  '';

  # Script to generate db.env
  generateDbEnv = pkgs.writeShellScript "generate-harbor-db-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${dbEnvTemplate} > /run/harbor/db.env
    chmod 600 /run/harbor/db.env
  '';

  # Bootstrap script to create projects and retention policies
  harborBootstrap = pkgs.writeShellScript "harbor-bootstrap" ''
    set -euo pipefail

    HARBOR_URL="http://localhost:8080"
    ADMIN_PASSWORD=$(cat ${config.age.secrets.harbor-admin-password.path})

    # Wait for Harbor to be healthy
    echo "Waiting for Harbor to be ready..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsS "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
        echo "Harbor is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "Harbor failed to become ready"
        exit 1
      fi
      sleep 5
    done

    # Check if project already exists
    PROJECT_EXISTS=$(${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/projects?name=oyabu" | ${pkgs.jq}/bin/jq 'length')

    if [ "$PROJECT_EXISTS" -eq 0 ]; then
      echo "Creating project 'oyabu'..."
      ${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/projects" \
        -d '{"project_name": "oyabu", "public": true, "storage_limit": 10737418240}'
      echo "Project created"
    else
      echo "Project 'oyabu' already exists"
    fi

    # Get project ID
    PROJECT_ID=$(${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/projects?name=oyabu" | ${pkgs.jq}/bin/jq -r '.[0].project_id')

    # Check if retention policy exists
    RETENTION_EXISTS=$(${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/retentions" 2>/dev/null | ${pkgs.jq}/bin/jq --arg pid "$PROJECT_ID" \
      '[.[] | select(.scope.ref == ($pid | tonumber))] | length' 2>/dev/null || echo "0")

    if [ "$RETENTION_EXISTS" -eq 0 ]; then
      echo "Creating retention policy..."
      ${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/retentions" \
        -d '{
          "algorithm": "or",
          "scope": {
            "level": "project",
            "ref": '"$PROJECT_ID"'
          },
          "trigger": {
            "kind": "Schedule",
            "settings": {
              "cron": "0 0 0 * * *"
            }
          },
          "rules": [
            {
              "disabled": false,
              "action": "retain",
              "scope_selectors": {
                "repository": [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}]
              },
              "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": "**"}],
              "params": {"latestPushedK": 2},
              "template": "latestPushedK"
            },
            {
              "disabled": false,
              "action": "retain",
              "scope_selectors": {
                "repository": [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}]
              },
              "tag_selectors": [{"kind": "doublestar", "decoration": "untagged", "pattern": ""}],
              "params": {"nDaysSinceLastPush": 2},
              "template": "nDaysSinceLastPush"
            }
          ]
        }'
      echo "Retention policy created: keep last 2 tags, delete untagged after 2 days"
    else
      echo "Retention policy already exists"
    fi

    echo "Harbor bootstrap complete"
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

  environment.etc."harbor/nginx.conf" = {
    mode = "0644";
    source = ./config/nginx.conf;
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
      volumes = [
        "/etc/harbor/nginx.conf:/etc/nginx/nginx.conf:ro"
      ];
      dependsOn = ["harbor-core"];
      extraOptions = [
        "--network=harbor-net"
      ];
    };

    # Trivy vulnerability scanner
    harbor-trivy = {
      image = "goharbor/trivy-adapter-photon:v2.11.2";
      autoStart = true;
      volumes = [
        "harbor_trivy_cache:/home/scanner/.cache"
      ];
      environment = {
        SCANNER_LOG_LEVEL = "info";
        SCANNER_TRIVY_CACHE_DIR = "/home/scanner/.cache/trivy";
        SCANNER_TRIVY_REPORTS_DIR = "/home/scanner/.cache/reports";
        SCANNER_TRIVY_VULN_TYPE = "os,library";
        SCANNER_TRIVY_SEVERITY = "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL";
        SCANNER_TRIVY_IGNORE_UNFIXED = "false";
        SCANNER_TRIVY_SKIP_UPDATE = "false";
        SCANNER_TRIVY_GITHUB_TOKEN = "";
        SCANNER_REDIS_URL = "redis://harbor-redis:6379/5";
        SCANNER_STORE_REDIS_URL = "redis://harbor-redis:6379/5";
        SCANNER_JOB_QUEUE_REDIS_URL = "redis://harbor-redis:6379/5";
      };
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=curl -fsS http://localhost:8080/probe/healthy || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
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
      "podman-harbor-trivy.service"
    ];
    before = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-portal.service"
      "podman-harbor-trivy.service"
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

  systemd.services.podman-harbor-trivy = {
    after = ["podman-harbor-redis.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };

  # Bootstrap service to create projects and retention policies
  systemd.services.harbor-bootstrap = {
    description = "Harbor bootstrap - create projects and retention policies";
    wantedBy = ["multi-user.target"];
    after = ["podman-harbor-core.service"];
    requires = ["podman-harbor-core.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${harborBootstrap}";
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
