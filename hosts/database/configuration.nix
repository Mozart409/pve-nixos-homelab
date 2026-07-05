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
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
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

  # Terraform state database password
  age.secrets.terraform-state-db-password = {
    file = ../../secrets/terraform-state-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # Forgejo database password
  age.secrets.forgejo-db-password = {
    file = ../../secrets/forgejo-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # Buildbot database password
  age.secrets.buildbot-db-password = {
    file = ../../secrets/buildbot-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # RomM database password
  age.secrets.romm-db-password = {
    file = ../../secrets/romm-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # pgAdmin initial (internal fallback) admin password and Pocket-ID OAuth2 client
  # secret. Both are consumed by the pgAdmin service below via systemd credentials
  # (root-owned 0400 by default is fine: systemd reads them during unit setup).
  age.secrets.pgadmin-pwd.file = ../../secrets/pgadmin-pwd.age;
  age.secrets.pgadmin-oauth2-secret.file = ../../secrets/pgadmin-oauth2-secret.age;

  # postgres superuser password so TCP clients (pgAdmin, etc.) can authenticate
  # over scram-sha-256 as a full DBA. The passwordless `peer` rule only covers the
  # postgres OS user on the local unix socket, which pgAdmin cannot use.
  age.secrets.postgres-superuser-password = {
    file = ../../secrets/postgres-superuser-password.age;
    owner = "postgres";
    group = "postgres";
  };

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
      host    all             all             100.64.0.0/10           scram-sha-256
    '';

    # Initial databases (names must match usernames when using ensureDBOwnership)
    ensureDatabases = ["appdb" "appuser" "terraform" "forgejo" "buildbot" "romm"];

    # Initial users
    ensureUsers = [
      {
        name = "appuser";
        ensureDBOwnership = true;
      }
      {
        name = "terraform";
        ensureDBOwnership = true;
      }
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
      {
        name = "buildbot";
        ensureDBOwnership = true;
      }
      {
        name = "romm";
        ensureDBOwnership = true;
      }
    ];
  };

  # Set password for terraform user after PostgreSQL creates the user
  systemd.services.postgresql-terraform-password = {
    description = "Set Terraform PostgreSQL user password";
    # Depends on postgresql.service, not postgresql-ensure-users.service (which
    # does not exist in this nixpkgs); ensureUsers runs in postgresql.service's
    # postStart, so the role exists once that unit is up.
    after = ["postgresql.service" "agenix.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      PASSWORD=$(cat ${config.age.secrets.terraform-state-db-password.path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER terraform WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Set password for forgejo user after PostgreSQL creates the user
  systemd.services.postgresql-forgejo-password = {
    description = "Set Forgejo PostgreSQL user password";
    # Depends on postgresql.service, not postgresql-ensure-users.service (which
    # does not exist in this nixpkgs); ensureUsers runs in postgresql.service's
    # postStart, so the role exists once that unit is up.
    after = ["postgresql.service" "agenix.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      PASSWORD=$(cat ${config.age.secrets.forgejo-db-password.path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER forgejo WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Set password for buildbot user after PostgreSQL creates the user
  systemd.services.postgresql-buildbot-password = {
    description = "Set Buildbot PostgreSQL user password";
    after = ["postgresql.service" "agenix.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      PASSWORD=$(cat ${config.age.secrets.buildbot-db-password.path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER buildbot WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Set password for romm user after PostgreSQL creates the user.
  # Depends on postgresql.service (not postgresql-ensure-users.service, which
  # does not exist in this nixpkgs — ensureUsers runs in postgresql.service's
  # postStart, so the role exists once that unit is up).
  systemd.services.postgresql-romm-password = {
    description = "Set RomM PostgreSQL user password";
    after = ["postgresql.service" "agenix.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      PASSWORD=$(cat ${config.age.secrets.romm-db-password.path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER romm WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Set the postgres superuser password from agenix. Depends on
  # postgresql.service (role creation runs in its postStart), not the nonexistent
  # postgresql-ensure-users.service — same gotcha as the other setters above.
  systemd.services.postgresql-superuser-password = {
    description = "Set postgres superuser password";
    after = ["postgresql.service" "agenix.service"];
    requires = ["postgresql.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      PASSWORD=$(cat ${config.age.secrets.postgres-superuser-password.path})
      ${config.services.postgresql.package}/bin/psql -c "ALTER USER postgres WITH PASSWORD '$PASSWORD';"
    '';
  };

  # Backup configuration
  services.postgresqlBackup = {
    enable = true;
    databases = ["appdb" "terraform" "forgejo" "buildbot" "romm"];
    location = "/var/backup/postgresql";
    startAt = "03:00";
    compression = "zstd";
  };

  # PgBouncer connection pooler
  services.pgbouncer = {
    enable = true;
    settings = {
      pgbouncer = {
        listen_addr = "127.0.0.1";
        listen_port = 6432;
        auth_type = "scram-sha-256";
        auth_file = "/var/lib/pgbouncer/userlist.txt";
        pool_mode = "transaction";
        max_client_conn = 200;
        default_pool_size = 20;
        min_pool_size = 5;
        reserve_pool_size = 5;
        # Required for prometheus exporter and some clients
        ignore_startup_parameters = "extra_float_digits";
        admin_users = "postgres";
        stats_users = "postgres";
      };
      databases = {
        # Pooled connection to appdb
        appdb = "host=/run/postgresql port=5432 dbname=appdb";
        # Wildcard - any database name not listed will connect to same-named db
        "*" = "host=/run/postgresql port=5432";
      };
    };
  };

  # Create pgbouncer auth file with postgres user
  # In production, use agenix for the password
  systemd.services.pgbouncer-userlist = {
    description = "Generate PgBouncer userlist";
    wantedBy = ["pgbouncer.service"];
    before = ["pgbouncer.service"];
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /var/lib/pgbouncer
      # Get password hash from PostgreSQL for scram-sha-256 auth
      HASH=$(${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/psql -t -A -c "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null || echo "")
      if [ -n "$HASH" ]; then
        echo "\"postgres\" \"$HASH\"" > /var/lib/pgbouncer/userlist.txt
      else
        # Fallback: create empty file, auth will use auth_query instead
        touch /var/lib/pgbouncer/userlist.txt
      fi
      chown pgbouncer:pgbouncer /var/lib/pgbouncer/userlist.txt
      chmod 600 /var/lib/pgbouncer/userlist.txt
    '';
  };

  # Prometheus exporter
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

  # pgAdmin 4 - native NixOS service (no container). Binds 127.0.0.1:5050; Caddy
  # (below) terminates step-ca TLS at pgadmin.homelab.local and reverse-proxies to
  # it. Auth is Pocket-ID OIDC (same provider as forgejo/romm/harbor) with an
  # internal fallback admin account (initialEmail + pgadmin-pwd).
  services.pgadmin = {
    enable = true;
    port = 5050;
    openFirewall = false;
    initialEmail = "claude@mozart409.com";
    initialPasswordFile = config.age.secrets.pgadmin-pwd.path;
    minimumPasswordLength = 8;
    settings = {
      # Loopback only; Caddy is the sole ingress.
      DEFAULT_SERVER = "127.0.0.1";
      # Trust Caddy's X-Forwarded-* headers so pgAdmin builds OAuth redirect URIs
      # as https://pgadmin.homelab.local/... not http://127.0.0.1:5050/...
      PROXY_X_FOR_COUNT = 1;
      PROXY_X_PROTO_COUNT = 1;
      PROXY_X_HOST_COUNT = 1;
      PROXY_X_PORT_COUNT = 1;
      PROXY_X_PREFIX_COUNT = 1;
      # OAuth2 (Pocket-ID) plus the internal admin account as a fallback.
      AUTHENTICATION_SOURCES = ["oauth2" "internal"];
      OAUTH2_AUTO_CREATE_USER = true;
    };
  };

  # Inject the Pocket-ID OAuth2 client secret WITHOUT leaking it into the
  # world-readable Nix store. This mirrors the pgadmin module's own
  # email-password mechanism: systemd LoadCredential exposes the agenix secret
  # under $CREDENTIALS_DIRECTORY, and the Python appended below (config_system.py
  # is a types.lines option, so definitions concatenate) reads it at import time.
  # OAUTH2_CONFIG lives here rather than in services.pgadmin.settings precisely so
  # the secret never passes through a store path.
  systemd.services.pgadmin.serviceConfig.LoadCredential = [
    "oauth2_client_secret:${config.age.secrets.pgadmin-oauth2-secret.path}"
  ];

  environment.etc."pgadmin/config_system.py".text = ''
    import os
    with open(os.path.join(os.environ['CREDENTIALS_DIRECTORY'], 'oauth2_client_secret')) as _f:
        _pgadmin_oauth2_secret = _f.read().strip()

    OAUTH2_CONFIG = [
        {
            'OAUTH2_NAME': 'pocket-id',
            'OAUTH2_DISPLAY_NAME': 'Pocket ID',
            # Public OAuth client identifier (not a secret) for the pgAdmin
            # client registered in Pocket-ID.
            'OAUTH2_CLIENT_ID': '4c1fd86d-dd3d-4920-82a8-ce53db286579',
            'OAUTH2_CLIENT_SECRET': _pgadmin_oauth2_secret,
            'OAUTH2_AUTHORIZATION_URL': 'https://pocketid.dropbear-butterfly.ts.net/authorize',
            'OAUTH2_TOKEN_URL': 'https://pocketid.dropbear-butterfly.ts.net/api/oidc/token',
            'OAUTH2_API_BASE_URL': 'https://pocketid.dropbear-butterfly.ts.net/',
            'OAUTH2_USERINFO_ENDPOINT': 'https://pocketid.dropbear-butterfly.ts.net/api/oidc/userinfo',
            'OAUTH2_SERVER_METADATA_URL': 'https://pocketid.dropbear-butterfly.ts.net/.well-known/openid-configuration',
            'OAUTH2_SCOPE': 'openid email profile',
            'OAUTH2_USERNAME_CLAIM': 'email',
            'OAUTH2_ICON': 'fa-key',
            'OAUTH2_BUTTON_COLOR': '#3253a8',
        },
    ]
  '';

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-database.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          respond "OK" 200
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."database.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          respond "OK" 200
        }
      '';
    };

    # pgAdmin 4 (native service on 127.0.0.1:5050) served with a step-ca cert.
    virtualHosts."pgadmin.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:5050
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      5432 # PostgreSQL
      6432 # PgBouncer
      9100 # Node exporter
      9187 # Postgres exporter
    ];
  };

  # Additional database management tools
  environment.systemPackages = with pkgs; [
    postgresql_18
    # pgcli  # Disabled - test failures in nixpkgs unstable
    pg_top
    pg_activity
  ];

  # Create backup directory and ensure postgres data directory is NoCoW (for Btrfs)
  systemd.tmpfiles.rules = [
    "d /var/backup/postgresql 0700 postgres postgres -"
    "d /var/lib/postgresql 0750 postgres postgres - +C"
  ];
}
