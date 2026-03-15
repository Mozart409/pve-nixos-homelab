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

  # Agenix secrets
  age.secrets.pgadmin-pwd = {
    file = ../../secrets/pgadmin-pwd.age;
    owner = "pgadmin";
    group = "pgadmin";
  };

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

  # pgAdmin4 web interface
  services.pgadmin = {
    enable = true;
    port = 5050;
    initialEmail = "admin@homelab.dev";
    initialPasswordFile = config.age.secrets.pgadmin-pwd.path;
    settings = {
      COOKIE_DEFAULT_PATH = "/pgadmin";
    };
  };

  # Ensure pgadmin starts after agenix secrets are available
  systemd.services.pgadmin = {
    wants = ["agenix.service"];
    after = ["agenix.service"];
  };

  # pgAdmin server definitions (imported on first boot)
  environment.etc."pgadmin/servers.json".text = builtins.toJSON {
    Servers = {
      "1" = {
        Name = "Local PostgreSQL";
        Group = "Homelab";
        Host = "localhost";
        Port = 5432;
        MaintenanceDB = "postgres";
        Username = "postgres";
        Comment = "Direct connection to local PostgreSQL";
        ConnectionParameters = {
          sslmode = "prefer";
          connect_timeout = 10;
        };
      };
      "2" = {
        Name = "Local PostgreSQL (PgBouncer)";
        Group = "Homelab";
        Host = "localhost";
        Port = 6432;
        MaintenanceDB = "postgres";
        Username = "postgres";
        Comment = "Connection via PgBouncer connection pooler";
        ConnectionParameters = {
          sslmode = "prefer";
          connect_timeout = 10;
        };
      };
    };
  };

  # Import pgAdmin servers on first boot
  systemd.services.pgadmin-import-servers = {
    description = "Import pgAdmin server definitions";
    wantedBy = ["multi-user.target"];
    after = ["pgadmin.service"];
    requires = ["pgadmin.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "pgadmin";
      Group = "pgadmin";
    };
    # Only import if not already done (check for marker file)
    script = ''
      MARKER="/var/lib/pgadmin/.servers-imported"
      if [ ! -f "$MARKER" ]; then
        # Wait for pgadmin to be fully initialized
        sleep 5
        ${config.services.pgadmin.package}/bin/pgadmin4-cli load-servers \
          /etc/pgadmin/servers.json \
          --user "${config.services.pgadmin.initialEmail}" \
          --replace
        touch "$MARKER"
        echo "pgAdmin servers imported successfully"
      else
        echo "pgAdmin servers already imported, skipping"
      fi
    '';
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;
    virtualHosts."homelab-database.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle /pgadmin* {
          reverse_proxy localhost:5050 {
            header_up X-Script-Name /pgadmin
          }
        }

        handle {
          respond "OK" 200
        }
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
