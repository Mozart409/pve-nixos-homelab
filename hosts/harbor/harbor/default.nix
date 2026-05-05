{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/harbor";

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
    JOBSERVICE_URL=http://harbor-jobservice:8080
    KEY=__CORE_SECRET__
    _REDIS_URL_CORE=redis://harbor-redis:6379/0
    _REDIS_URL_REG=redis://harbor-redis:6379/1
    EXT_ENDPOINT=https://homelab-harbor.dropbear-butterfly.ts.net
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

  jobserviceEnvTemplate = pkgs.writeText "harbor-jobservice-env-template" ''
    CORE_SECRET=__CORE_SECRET__
    JOBSERVICE_SECRET=__CORE_SECRET__
    CORE_URL=http://harbor-core:8080
    REGISTRY_URL=http://harbor-registry:5000
    REGISTRY_CONTROLLER_URL=http://harbor-registry:5000
    TOKEN_SERVICE_URL=http://harbor-core:8080/service/token
    _REDIS_URL_JOB=redis://harbor-redis:6379/2
  '';

  generateDbEnv = pkgs.writeShellScript "generate-harbor-db-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${dbEnvTemplate} > /run/harbor/db.env
    chmod 600 /run/harbor/db.env
  '';

  harborBootstrap = pkgs.writeShellScript "harbor-bootstrap" ''
    set -uo pipefail

    HARBOR_URL="http://localhost:8080"
    ADMIN_PASSWORD=$(cat ${config.age.secrets.harbor-admin-password.path})

    echo "Waiting for Harbor Core to be ready..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsS "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
        echo "Harbor Core is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "Harbor Core failed to become ready"
        exit 1
      fi
      sleep 5
    done

    echo "Waiting for Harbor Jobservice to be ready..."
    for i in $(seq 1 60); do
      if ${pkgs.podman}/bin/podman exec harbor-jobservice curl -fsS http://localhost:8080/api/v1/stats >/dev/null 2>&1; then
        echo "Harbor Jobservice is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "Harbor Jobservice failed to become ready"
        exit 1
      fi
      sleep 5
    done

    # Check current auth mode - if OIDC is already configured, skip project/retention setup
    # (admin basic auth doesn't work reliably after OIDC is enabled)
    CURRENT_AUTH=$(${pkgs.curl}/bin/curl -sS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/configurations" 2>/dev/null | ${pkgs.jq}/bin/jq -r '.auth_mode.value // "db_auth"' 2>/dev/null || echo "unknown")

    if [ "$CURRENT_AUTH" = "oidc_auth" ]; then
      echo "OIDC already configured, updating settings only..."
      OIDC_CLIENT_ID=$(cat ${config.age.secrets.harbor-oidc-client-id.path})
      OIDC_CLIENT_SECRET=$(cat ${config.age.secrets.harbor-oidc-client-secret.path})

      ${pkgs.curl}/bin/curl -sS -X PUT -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/configurations" \
        -d '{
          "oidc_name": "Pocket ID",
          "oidc_endpoint": "https://pocketid.dropbear-butterfly.ts.net",
          "oidc_client_id": "'"$OIDC_CLIENT_ID"'",
          "oidc_client_secret": "'"$OIDC_CLIENT_SECRET"'",
          "oidc_groups_claim": "groups",
          "oidc_admin_group": "admins",
          "oidc_scope": "openid,offline_access,email,profile,groups",
          "oidc_verify_cert": true,
          "oidc_auto_onboard": true,
          "oidc_user_claim": "email"
        }' >/dev/null 2>&1 || echo "OIDC update may have failed (auth mode already OIDC)"

      echo "Harbor bootstrap complete (OIDC update only)"
      exit 0
    fi

    echo "Fresh install detected, running full bootstrap..."

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

    PROJECT_ID=$(${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/projects?name=oyabu" | ${pkgs.jq}/bin/jq -r '.[0].project_id')

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

    OIDC_CLIENT_ID=$(cat ${config.age.secrets.harbor-oidc-client-id.path})
    OIDC_CLIENT_SECRET=$(cat ${config.age.secrets.harbor-oidc-client-secret.path})

    echo "Configuring OIDC authentication with Pocket ID..."
    ${pkgs.curl}/bin/curl -fsS -X PUT -u "admin:$ADMIN_PASSWORD" \
      -H "Content-Type: application/json" \
      "$HARBOR_URL/api/v2.0/configurations" \
      -d '{
        "auth_mode": "oidc_auth",
        "oidc_name": "Pocket ID",
        "oidc_endpoint": "https://pocketid.dropbear-butterfly.ts.net",
        "oidc_client_id": "'"$OIDC_CLIENT_ID"'",
        "oidc_client_secret": "'"$OIDC_CLIENT_SECRET"'",
        "oidc_groups_claim": "groups",
        "oidc_admin_group": "admins",
        "oidc_scope": "openid,offline_access,email,profile,groups",
        "oidc_verify_cert": true,
        "oidc_auto_onboard": true,
        "oidc_user_claim": "email",
        "primary_auth_mode": false
      }'
    echo "OIDC authentication configured"

    echo "Harbor bootstrap complete"
  '';

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
    # Create the secret key file for encrypting config values
    # Harbor requires exactly 16 bytes for AES-128
    # Harbor core runs as UID 10000, needs read access
    echo -n "$CORE_SECRET" | ${pkgs.coreutils}/bin/head -c 16 > /run/harbor/secretkey
    chmod 644 /run/harbor/secretkey
    # Generate RSA private key for JWT token signing (only if not exists)
    if [ ! -f /run/harbor/private_key.pem ]; then
      ${pkgs.openssl}/bin/openssl genrsa -out /run/harbor/private_key.pem 4096
      chmod 644 /run/harbor/private_key.pem
    fi
  '';

  generateJobserviceEnv = pkgs.writeShellScript "generate-harbor-jobservice-env" ''
    mkdir -p /run/harbor
    CORE_SECRET=$(cat ${config.age.secrets.harbor-core-secret.path})
    ${pkgs.gnused}/bin/sed \
      -e "s/__CORE_SECRET__/$CORE_SECRET/" \
      ${jobserviceEnvTemplate} > /run/harbor/jobservice.env
    chmod 600 /run/harbor/jobservice.env
  '';
in {
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/registry 0755 root root -"
    "d ${dataDir}/database 0755 root root -"
  ];

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

  environment.etc."harbor/jobservice.yml" = {
    mode = "0644";
    source = ./config/jobservice.yml;
  };

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

  age.secrets.harbor-oidc-client-id = {
    file = ../../../secrets/harbor-oidc-client-id.age;
    mode = "0440";
    group = "root";
  };

  age.secrets.harbor-oidc-client-secret = {
    file = ../../../secrets/harbor-oidc-client-secret.age;
    mode = "0440";
    group = "root";
  };

  virtualisation.oci-containers.containers = {
    harbor-db = {
      image = "postgres:13-alpine";
      autoStart = true;
      volumes = ["harbor_db:/var/lib/postgresql/data"];
      environmentFiles = ["/run/harbor/db.env"];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=pg_isready -U harbor -d registry"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=5"
      ];
    };

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

    harbor-core = {
      image = "goharbor/harbor-core:v2.11.2";
      autoStart = true;
      ports = ["8080:8080"];
      volumes = [
        "/etc/harbor/core.conf:/etc/core/app.conf:ro"
        "/run/harbor/secretkey:/etc/core/key:ro"
        "/run/harbor/private_key.pem:/etc/core/private_key.pem:ro"
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

    harbor-jobservice = {
      image = "goharbor/harbor-jobservice:v2.11.2";
      autoStart = true;
      volumes = [
        "/etc/harbor/jobservice.yml:/etc/jobservice/config.yml:ro"
        "harbor_job_logs:/var/log/jobs"
      ];
      environmentFiles = ["/run/harbor/jobservice.env"];
      dependsOn = ["harbor-core" "harbor-redis"];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=curl -fsS http://localhost:8080/api/v1/stats || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
    };

    harbor-portal = {
      image = "goharbor/harbor-portal:v2.11.2";
      autoStart = true;
      ports = ["8081:8080"];
      volumes = ["/etc/harbor/nginx.conf:/etc/nginx/nginx.conf:ro"];
      dependsOn = ["harbor-core"];
      extraOptions = ["--network=harbor-net"];
    };

    harbor-trivy = {
      image = "goharbor/trivy-adapter-photon:v2.11.2";
      autoStart = true;
      volumes = ["harbor_trivy_cache:/home/scanner/.cache"];
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

  systemd.services.podman-network-harbor = {
    description = "Create podman network for harbor";
    wantedBy = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-jobservice.service"
      "podman-harbor-portal.service"
      "podman-harbor-trivy.service"
    ];
    before = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-jobservice.service"
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

  systemd.services.podman-harbor-db = {
    after = ["podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateDbEnv}"];
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
    serviceConfig.ExecStartPre = ["${generateCoreEnv}"];
  };

  systemd.services.podman-harbor-jobservice = {
    after = ["podman-harbor-core.service" "podman-harbor-redis.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateJobserviceEnv}"];
  };

  systemd.services.podman-harbor-portal = {
    after = ["podman-harbor-core.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };

  systemd.services.podman-harbor-trivy = {
    after = ["podman-harbor-redis.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
  };

  systemd.services.harbor-bootstrap = {
    description = "Harbor bootstrap - create projects and retention policies";
    wantedBy = ["multi-user.target"];
    after = ["podman-harbor-core.service" "podman-harbor-jobservice.service"];
    requires = ["podman-harbor-core.service" "podman-harbor-jobservice.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${harborBootstrap}";
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
