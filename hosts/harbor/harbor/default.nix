{
  config,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/harbor";

  dbEnvTemplate = pkgs.writeText "harbor-db-env-template" ''
    POSTGRES_DB=registry
    POSTGRES_USER=harbor
    POSTGRES_PASSWORD=__DB_PASSWORD__
  '';

  anchoreDbEnvTemplate = pkgs.writeText "harbor-anchore-db-env-template" ''
    POSTGRES_DB=anchore
    POSTGRES_USER=postgres
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

  anchoreEngineEnvTemplate = pkgs.writeText "harbor-anchore-engine-env-template" ''
    ANCHORE_ENDPOINT_HOSTNAME=harbor-anchore-engine
    ANCHORE_DB_HOST=harbor-anchore-db
    ANCHORE_DB_PORT=5432
    ANCHORE_DB_USER=postgres
    ANCHORE_DB_PASSWORD=__DB_PASSWORD__
    ANCHORE_DB_NAME=anchore
    ANCHORE_ADMIN_PASSWORD=__ANCHORE_ADMIN_PASSWORD__
    ANCHORE_PASSWORD=__ANCHORE_ADMIN_PASSWORD__
    ANCHORE_VULNERABILITIES_PROVIDER=grype
  '';

  generateDbEnv = pkgs.writeShellScript "generate-harbor-db-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${dbEnvTemplate} > /run/harbor/db.env
    chmod 600 /run/harbor/db.env
  '';

  generateAnchoreDbEnv = pkgs.writeShellScript "generate-harbor-anchore-db-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ${pkgs.gnused}/bin/sed "s/__DB_PASSWORD__/$DB_PASSWORD/" ${anchoreDbEnvTemplate} > /run/harbor/anchore-db.env
    chmod 600 /run/harbor/anchore-db.env
  '';

  generateAnchoreEngineEnv = pkgs.writeShellScript "generate-harbor-anchore-engine-env" ''
    mkdir -p /run/harbor
    DB_PASSWORD=$(cat ${config.age.secrets.harbor-db-password.path})
    ANCHORE_ADMIN_PASSWORD=$(cat ${config.age.secrets.harbor-core-secret.path})
    ${pkgs.gnused}/bin/sed \
      -e "s/__DB_PASSWORD__/$DB_PASSWORD/" \
      -e "s/__ANCHORE_ADMIN_PASSWORD__/$ANCHORE_ADMIN_PASSWORD/" \
      ${anchoreEngineEnvTemplate} > /run/harbor/anchore-engine.env
    chmod 600 /run/harbor/anchore-engine.env
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

    # Check current auth mode. Project bootstrap below runs regardless of
    # this -- primary_auth_mode is set to false further down, which keeps
    # the local admin/basic-auth superuser working even once OIDC is
    # enabled, so there is no need to skip project provisioning on repeat
    # runs (that used to short-circuit before the `ci` project existed --
    # see commit 5b66aad/54de129, which fixed this same bug in a stale
    # duplicate file that was never actually deployed).
    CURRENT_AUTH=$(${pkgs.curl}/bin/curl -sS -u "admin:$ADMIN_PASSWORD" \
      "$HARBOR_URL/api/v2.0/configurations" 2>/dev/null | ${pkgs.jq}/bin/jq -r '.auth_mode.value // "db_auth"' 2>/dev/null || echo "unknown")
    echo "Current auth mode: $CURRENT_AUTH"

    # Exact-match project lookup, emitting the project object or nothing.
    # Harbor's `?name=` filter is a FUZZY match, so a lookup for "ci" would
    # also return a project called "cicd" -- narrow it in jq instead of
    # trusting `.[0]`.
    project_json() {
      ${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
        "$HARBOR_URL/api/v2.0/projects?name=$1" \
        | ${pkgs.jq}/bin/jq -c --arg n "$1" '[.[] | select(.name == $n)] | .[0] // empty'
    }

    # Projects Woodpecker CI pulls from (harbor.homelab.local/ci/*) and the
    # app registry (harbor.homelab.local/oyabu/*) -- both public, both
    # bootstrapped the same way so a rebuilt Harbor host never silently
    # breaks CI image pulls with "project ci not found".
    for PROJECT_NAME in oyabu ci; do
      if [ -z "$(project_json "$PROJECT_NAME")" ]; then
        echo "Creating project '$PROJECT_NAME'..."
        ${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
          -H "Content-Type: application/json" \
          "$HARBOR_URL/api/v2.0/projects" \
          -d '{"project_name": "'"$PROJECT_NAME"'", "public": true, "storage_limit": 10737418240}'
        echo "Project created"
      else
        echo "Project '$PROJECT_NAME' already exists"
      fi

      PROJECT=$(project_json "$PROJECT_NAME")
      PROJECT_ID=$(printf '%s' "$PROJECT" | ${pkgs.jq}/bin/jq -r '.project_id')

      # Harbor records a project's retention policy as metadata.retention_id,
      # and a project may hold at most one. There is NO list-all GET on
      # /api/v2.0/retentions -- it is POST-only and a GET returns 405 -- so a
      # probe that GETs it would fail on every run, report "no policy", and
      # re-POST a duplicate for oyabu. Harbor rejects that, and under `set -e`
      # the rejection would kill the whole loop before the `ci` iteration.
      # Read the id off the project object instead.
      RETENTION_ID=$(printf '%s' "$PROJECT" | ${pkgs.jq}/bin/jq -r '.metadata.retention_id // ""')

      if [ -z "$RETENTION_ID" ]; then
        echo "Creating retention policy for '$PROJECT_NAME'..."
        # Non-fatal on purpose: a missing retention policy is a
        # disk-housekeeping concern, never a reason to abort the loop and
        # leave a later project -- and therefore CI -- broken.
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
          }' \
          && echo "Retention policy created for '$PROJECT_NAME': keep last 2 tags, delete untagged after 2 days" \
          || echo "WARNING: could not create retention policy for '$PROJECT_NAME'; continuing"
      else
        echo "Retention policy already exists for '$PROJECT_NAME' (id $RETENTION_ID)"
      fi
    done

    OIDC_CLIENT_ID=$(cat ${config.age.secrets.harbor-oidc-client-id.path})
    OIDC_CLIENT_SECRET=$(cat ${config.age.secrets.harbor-oidc-client-secret.path})

    if [ "$CURRENT_AUTH" = "oidc_auth" ]; then
      echo "OIDC already configured, updating settings only..."
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
    else
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
    fi
    echo "OIDC authentication configured"

    echo "Waiting for Anchore scanner adapter to be ready..."
    for i in $(seq 1 60); do
      if ${pkgs.podman}/bin/podman exec harbor-anchore-scanner-adapter curl -fsS http://localhost:8080/probe/healthy >/dev/null 2>&1; then
        echo "Anchore scanner adapter is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "Anchore scanner adapter failed to become ready"
        exit 1
      fi
      sleep 5
    done

    registry_json() {
      ${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
        "$HARBOR_URL/api/v2.0/registries?name=$1" \
        | ${pkgs.jq}/bin/jq -c --arg n "$1" '[.[] | select(.name == $n)] | .[0] // empty'
    }

    DOCKER_HUB_REGISTRY=$(registry_json "docker-hub")
    if [ -z "$DOCKER_HUB_REGISTRY" ]; then
      echo "Creating Docker Hub registry endpoint..."
      DOCKER_HUB_REGISTRY=$(${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/registries" \
        -d '{"name": "docker-hub", "url": "https://hub.docker.com", "type": "docker-hub", "credential_type": "basic", "insecure": false}' \
        | ${pkgs.jq}/bin/jq -c '.')
      echo "Docker Hub registry endpoint created"
    else
      echo "Docker Hub registry endpoint already exists"
    fi
    REGISTRY_ID=$(printf '%s' "$DOCKER_HUB_REGISTRY" | ${pkgs.jq}/bin/jq -r '.id // .registry_id // ""')

    if [ -n "$REGISTRY_ID" ] && [ -z "$(project_json "docker-hub")" ]; then
      echo "Creating docker-hub proxy-cache project..."
      ${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/projects" \
        -d '{"project_name": "docker-hub", "registry_id": '"$REGISTRY_ID"', "metadata": {"public": "true"}, "storage_limit": -1}'
      echo "Docker Hub proxy-cache project created"
    else
      echo "Docker Hub proxy-cache project already exists or registry endpoint unavailable"
    fi

    scanner_json() {
      ${pkgs.curl}/bin/curl -fsS -u "admin:$ADMIN_PASSWORD" \
        "$HARBOR_URL/api/v2.0/scanners?name=$1" \
        | ${pkgs.jq}/bin/jq -c --arg n "$1" '[.[] | select(.name == $n)] | .[0] // empty'
    }

    if [ -z "$(scanner_json "Anchore")" ]; then
      echo "Registering Anchore scanner adapter..."
      ${pkgs.curl}/bin/curl -fsS -X POST -u "admin:$ADMIN_PASSWORD" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/scanners" \
        -d '{"name": "Anchore", "description": "Anchore Engine scanner", "url": "http://harbor-anchore-scanner-adapter:8080", "auth": "", "access_credential": "None", "skip_cert_verify": true, "use_internal_addr": true}'
      echo "Anchore scanner registered"
    else
      echo "Anchore scanner already registered"
    fi

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
    # Harbor requires traditional RSA format (BEGIN RSA PRIVATE KEY), not PKCS#8
    if [ ! -f /run/harbor/private_key.pem ]; then
      ${pkgs.openssl}/bin/openssl genrsa -traditional -out /run/harbor/private_key.pem 4096
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

    harbor-anchore-db = {
      image = "postgres:13-alpine";
      autoStart = true;
      volumes = ["harbor_anchore_db:/var/lib/postgresql/data"];
      environmentFiles = ["/run/harbor/anchore-db.env"];
      extraOptions = [
        "--network=harbor-net"
        "--health-cmd=pg_isready -U postgres -d anchore"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=5"
      ];
    };

    harbor-anchore-catalog = {
      image = "anchore/anchore-engine:v1.1.0";
      autoStart = true;
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-db"];
      extraOptions = [
        "--network=harbor-net"
        "--entrypoint=anchore-manager"
        "--health-cmd=curl -fsS http://localhost:8228/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
      cmd = ["service" "start" "catalog"];
    };

    harbor-anchore-simplequeue = {
      image = "anchore/anchore-engine:v1.1.0";
      autoStart = true;
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-db" "harbor-anchore-catalog"];
      extraOptions = [
        "--network=harbor-net"
        "--entrypoint=anchore-manager"
        "--health-cmd=curl -fsS http://localhost:8228/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
      cmd = ["service" "start" "simplequeue"];
    };

    harbor-anchore-policy-engine = {
      image = "anchore/anchore-engine:v1.1.0";
      autoStart = true;
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-db" "harbor-anchore-catalog"];
      extraOptions = [
        "--network=harbor-net"
        "--entrypoint=anchore-manager"
        "--health-cmd=curl -fsS http://localhost:8228/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
      cmd = ["service" "start" "policy_engine"];
    };

    harbor-anchore-analyzer = {
      image = "anchore/anchore-engine:v1.1.0";
      autoStart = true;
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-db" "harbor-anchore-catalog"];
      extraOptions = [
        "--network=harbor-net"
        "--entrypoint=anchore-manager"
        "--health-cmd=curl -fsS http://localhost:8228/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
      cmd = ["service" "start" "analyzer"];
    };

    harbor-anchore-api = {
      image = "anchore/anchore-engine:v1.1.0";
      autoStart = true;
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-db" "harbor-anchore-catalog"];
      extraOptions = [
        "--network=harbor-net"
        "--entrypoint=anchore-manager"
        "--health-cmd=curl -fsS http://localhost:8228/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
      cmd = ["service" "start" "apiext"];
    };

    harbor-anchore-scanner-adapter = {
      image = "anchore/harbor-scanner-adapter:1.5.2";
      autoStart = true;
      environment = {
        SCANNER_ADAPTER_LISTEN_ADDR = ":8080";
        SCANNER_ADAPTER_LOG_LEVEL = "info";
        SCANNER_ADAPTER_REGISTRY_TLS_VERIFY = "false";
        ANCHORE_ENDPOINT = "http://harbor-anchore-api:8228";
        ANCHORE_USERNAME = "admin";
        ANCHORE_CLIENT_TIMEOUT_SECONDS = "60";
      };
      environmentFiles = ["/run/harbor/anchore-engine.env"];
      dependsOn = ["harbor-anchore-api"];
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
      "podman-harbor-anchore-db.service"
      "podman-harbor-anchore-catalog.service"
      "podman-harbor-anchore-simplequeue.service"
      "podman-harbor-anchore-policy-engine.service"
      "podman-harbor-anchore-analyzer.service"
      "podman-harbor-anchore-api.service"
      "podman-harbor-anchore-scanner-adapter.service"
    ];
    before = [
      "podman-harbor-db.service"
      "podman-harbor-redis.service"
      "podman-harbor-registry.service"
      "podman-harbor-core.service"
      "podman-harbor-jobservice.service"
      "podman-harbor-portal.service"
      "podman-harbor-trivy.service"
      "podman-harbor-anchore-db.service"
      "podman-harbor-anchore-catalog.service"
      "podman-harbor-anchore-simplequeue.service"
      "podman-harbor-anchore-policy-engine.service"
      "podman-harbor-anchore-analyzer.service"
      "podman-harbor-anchore-api.service"
      "podman-harbor-anchore-scanner-adapter.service"
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

  systemd.services.podman-harbor-anchore-db = {
    after = ["podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreDbEnv}"];
  };

  systemd.services.podman-harbor-anchore-catalog = {
    after = ["podman-harbor-anchore-db.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.podman-harbor-anchore-simplequeue = {
    after = ["podman-harbor-anchore-db.service" "podman-harbor-anchore-catalog.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.podman-harbor-anchore-policy-engine = {
    after = ["podman-harbor-anchore-db.service" "podman-harbor-anchore-catalog.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.podman-harbor-anchore-analyzer = {
    after = ["podman-harbor-anchore-db.service" "podman-harbor-anchore-catalog.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.podman-harbor-anchore-api = {
    after = ["podman-harbor-anchore-db.service" "podman-harbor-anchore-catalog.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.podman-harbor-anchore-scanner-adapter = {
    after = ["podman-harbor-anchore-api.service" "podman-network-harbor.service"];
    requires = ["podman-network-harbor.service"];
    serviceConfig.ExecStartPre = ["${generateAnchoreEngineEnv}"];
  };

  systemd.services.harbor-bootstrap = {
    description = "Harbor bootstrap - create projects, retention policies, proxy cache and scanner";
    wantedBy = ["multi-user.target"];
    after = ["podman-harbor-core.service" "podman-harbor-jobservice.service" "podman-harbor-anchore-scanner-adapter.service"];
    requires = ["podman-harbor-core.service" "podman-harbor-jobservice.service" "podman-harbor-anchore-scanner-adapter.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${harborBootstrap}";
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
