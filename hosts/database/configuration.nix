{
  config,
  lib,
  pkgs,
  ...
}: let
  psql = "${config.services.postgresql.package}/bin/psql";

  # The exemption every service role that runs schema migrations needs from the
  # cluster-wide defaults in services.postgresql.settings. `0` disables the
  # bound for that role only; the global value still applies to everyone else.
  # Kept as one binding so the exemption list is a single reviewable fact
  # rather than the same three lines repeated per role.
  migrationRoleTimeouts = {
    statement_timeout = "0";
    lock_timeout = "0";
    transaction_timeout = "0";
  };

  # Every role password is set the same way: a oneshot that reads the agenix
  # secret and ALTERs the role. Only the description, the role and the extra
  # SQL ever differed across the seven copies this replaces.
  #
  # ORDERING GOTCHA -- do not "simplify" after/requires below.
  # Order on postgresql-SETUP.service, never postgresql.service.
  # ensureUsers/ensureDatabases run in the setup unit; postgresql.service
  # reports ready as soon as the server accepts connections, which is well
  # before any role has been created. Ordering only on postgresql.service
  # races role creation and fails with `role "<name>" does not exist` -- but
  # only on the deploy that first introduces the role, so the bug stays
  # dormant afterwards and a green deploy proves nothing. This failed exactly
  # that way when the mcp role was added (2026-07-31).
  # (postgresql-ensure-users.service does not exist in this nixpkgs.)
  #
  # Centralising it here means that comment is now enforced in one place
  # instead of restated seven times and hopefully copied correctly the eighth.
  #
  # `timeouts` is an attrset of GUC name -> raw SQL literal, applied with
  # ALTER ROLE ... SET. Values are literals, not Nix strings: a quoted duration
  # like "'30s'", or "0" to disable that bound for this role only. It exists so
  # the generous cluster-wide defaults in services.postgresql.settings can be
  # overridden per role in the one place that already knows about each role.
  mkRolePasswordUnit = {
    role,
    description,
    secret,
    timeouts ? {},
    extraSql ? [],
  }: {
    inherit description;
    after = ["postgresql-setup.service" "agenix.service"];
    requires = ["postgresql-setup.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script =
      ''
        PASSWORD=$(cat ${secret.path})
        ${psql} -c "ALTER USER ${role} WITH PASSWORD '$PASSWORD';"
      ''
      + lib.concatMapStrings (sql: "${psql} -c \"${sql}\"\n") (
        extraSql
        ++ lib.mapAttrsToList (guc: value: "ALTER ROLE ${role} SET ${guc} = ${value};") timeouts
      );
  };
in {
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

  # RomM database password
  age.secrets.romm-db-password = {
    file = ../../secrets/romm-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # hofvarpnir database password
  age.secrets.hofvarpnir-db-password = {
    file = ../../secrets/hofvarpnir-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # attic (binary cache index) database password. The same password is embedded
  # in attic-db-url.age on the cache host — rotating it means re-encrypting both.
  age.secrets.attic-db-password = {
    file = ../../secrets/attic-db-password.age;
    owner = "postgres";
    group = "postgres";
  };

  # pgAdmin initial (internal fallback) admin password and Pocket-ID OAuth2 client
  # secret. Both are consumed by the pgAdmin service below via systemd credentials
  # (root-owned 0400 by default is fine: systemd reads them during unit setup).
  age.secrets.pgadmin-pwd.file = ../../secrets/pgadmin-pwd.age;
  age.secrets.pgadmin-oauth2-secret.file = ../../secrets/pgadmin-oauth2-secret.age;

  # Password for the read-only `mcp` role consumed by the pgmcp MCP servers on
  # the mcp host. The same password is embedded in each pg-mcp-<db>-url.age
  # secret over there — rotating it means re-encrypting all of them.
  age.secrets.pgmcp-role-password = {
    file = ../../secrets/pgmcp-role-password.age;
    owner = "postgres";
    group = "postgres";
  };

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

      # Logging. This host's pool is 2 HDDs at ~78 IOPS cluster-wide (see the
      # pgadmin TimeoutStartSec note below), and journald fsyncs, so log volume
      # is a direct tax on the same spindles every query needs. `log_statement =
      # "all"` + `log_duration = true` wrote TWO journal lines for EVERY
      # statement -- including the prometheus exporter's pg_stat_* polling every
      # 15s across 7 databases -- which is almost entirely noise.
      #
      # Replaced by: DDL always (the migration audit trail is the part actually
      # worth keeping -- it is what you reach for when atticd breaks), plus
      # statement text and duration only above 1s. On this hardware a query
      # doing a few hundred random reads legitimately takes ~1s, so above that
      # is pathological rather than merely cold.
      #
      # log_duration MUST be false: left on, it re-logs a duration line for
      # every statement and defeats log_min_duration_statement entirely.
      log_statement = "ddl";
      log_duration = false;
      log_min_duration_statement = "1s";

      # Attribute a slow line to a role/database/application, not just a pid.
      # The default is "%m [%p] ". %q suppresses the rest for non-session lines.
      log_line_prefix = "%m [%p] %q%u@%d/%a ";

      # Cheap, high-signal diagnostics for a slow-disk box: who waited on a lock
      # (>deadlock_timeout, 1s), which sorts/hashes spilled past work_mem (4MB)
      # onto the HDDs, and when autovacuum ate the disk.
      log_lock_waits = true;
      log_temp_files = "10MB";
      log_autovacuum_min_duration = "10s";
      # log_checkpoints is already on by default in PG15+.

      # Session hardening. Only settings that target a PATHOLOGY belong at
      # cluster scope -- anything here applies to pg_dump, the prometheus
      # exporter and atticd's sea-orm startup migrations alike. Everything that
      # can ABORT work is scoped per-role instead (see the mcp setter below).
      #
      # An abandoned open transaction is the one failure that compounds on this
      # hardware: it pins the xmin horizon so autovacuum cannot reclaim, bloat
      # grows, and bloat costs IOPS this pool does not have. This fires only on
      # a session that is IDLE inside a transaction -- a session actually
      # running a statement is never touched, so migrations and pg_dump are
      # unaffected by construction. 2min is far longer than any client here
      # legitimately idles mid-transaction (pgAdmin's query tool is the usual
      # producer).
      idle_in_transaction_session_timeout = "2min";

      # Reap backends whose client is gone. Postgres inherits the kernel's ~2h
      # dead-peer detection; homelab VMs are rebooted by colmena constantly, so
      # those backends hold connection slots and locks for hours. 60s idle plus
      # 6 probes 10s apart bounds it to ~2min. This affects only TCP peers that
      # have stopped answering -- an idle-but-alive session is untouched, which
      # is the whole point (see idle_session_timeout below).
      tcp_keepalives_idle = 60;
      tcp_keepalives_interval = 10;
      tcp_keepalives_count = 6;

      # The remaining bounds are set cluster-wide as GENEROUS defaults, so that
      # anything nobody thought about -- a human in pgAdmin's query tool, an
      # ad-hoc psql, a service added later that nobody tuned -- is bounded by
      # default rather than able to pin this pool indefinitely.
      #
      # They are deliberately far looser than the per-role values, because a
      # global default here also applies to pg_dump, the prometheus exporter
      # and atticd's sea-orm startup migrations. The roles whose work
      # legitimately outruns these are exempted individually, next to their
      # password setters below -- see `timeouts` on each mkRolePasswordUnit
      # call. Exempting by role rather than loosening the default keeps the
      # exception list explicit and reviewable.
      #
      # If a service starts failing after a deploy with "canceling statement
      # due to statement timeout", the fix is an exemption on ITS role, not
      # raising these.

      # 5min: no interactive query and no steady-state service query on this
      # box legitimately runs five minutes. The things that do -- migrations,
      # backups, terraform state ops -- are all exempted by role.
      statement_timeout = "5min";

      # 1min: a lock wait past a minute means a real blocker is sitting in
      # front of you, and failing fast beats queueing behind it. Migration
      # roles that legitimately take ACCESS EXCLUSIVE are exempted.
      lock_timeout = "1min";

      # 15min: outer bound on a whole multi-statement transaction. Set above
      # statement_timeout on purpose, so it only ever catches a runaway that
      # individual statements slipped past, never a single slow query.
      transaction_timeout = "15min";

      # 8h: reaps sessions whose client is gone but whose TCP connection never
      # broke cleanly. Deliberately long -- the terraform `pg` backend holds
      # its state lock as a SESSION-level advisory lock and idles for the whole
      # plan/apply, so this must never fire mid-apply; terraform is exempted
      # outright as well, belt and braces. Dead TCP peers are handled far
      # faster by the keepalives above; this only catches the rest.
      idle_session_timeout = "8h";
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
    # `appuser` is deliberately absent: it was a scratch database with no
    # writer, reachable only through its own pgmcp instance, and both were
    # dropped. Removing it here does NOT drop the live database or role --
    # ensureDatabases only ever creates. See the note in hosts/mcp_vm.
    ensureDatabases = ["appdb" "terraform" "forgejo" "romm" "hofvarpnir" "attic"];

    # Initial users
    ensureUsers = [
      {
        name = "terraform";
        ensureDBOwnership = true;
      }
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
      {
        name = "romm";
        ensureDBOwnership = true;
      }
      {
        name = "hofvarpnir";
        ensureDBOwnership = true;
      }
      # atticd on the cache host. Owns its database because sea-orm runs schema
      # migrations at startup, so it needs DDL rights, not just DML.
      {
        name = "attic";
        ensureDBOwnership = true;
      }
      # Read-only role for the pgmcp MCP servers. No ensureDBOwnership: it owns
      # nothing and must never create anything. CONNECT is granted to PUBLIC on
      # every database by default, so this role reaches all of them; read access
      # comes from pg_read_all_data below.
      {
        name = "mcp";
      }
    ];
  };

  # Set the password and read-only grants for the pgmcp `mcp` role.
  systemd.services.postgresql-mcp-password = mkRolePasswordUnit {
    role = "mcp";
    description = "Set pgmcp PostgreSQL role password and read-only grants";
    secret = config.age.secrets.pgmcp-role-password;
    # pg_read_all_data is a cluster-wide predefined role (PG14+): membership
    # grants SELECT on every table, view and sequence in *every* database,
    # including ones created later, without per-database grants. Pairing it with
    # a read-only default transaction means the role cannot write even if pgmcp
    # ever sent something other than a SELECT.
    #
    # The timeouts below are scoped to this role via the same ALTER ROLE ... SET
    # mechanism, precisely so a global default cannot reach atticd's startup
    # migrations. mcp is the only role here executing queries nobody wrote or
    # reviewed -- pgmcp's run_query passes LLM-authored SQL straight through --
    # and the only role that cannot be harmed by being told "no".
    #
    # 30s statement: pgmcp calls are LLM tool calls with their own request
    #   deadline, so a query that outlives 30s produces no answer anyone will
    #   read; it only burns IOPS the rest of the cluster needs. The catalog
    #   tools are milliseconds; only run_query can run away.
    # 5s lock: read-only, so it only ever needs ACCESS SHARE. If it cannot get
    #   that in 5s a writer is doing DDL, and the right answer is to fail now
    #   rather than queue an LLM behind a migration.
    # 30s idle-in-transaction: tighter than the 2min cluster default; a
    #   read-only role has no reason to hold a transaction open at all.
    #
    # NOTE: ALTER ROLE ... SET is stored in pg_db_role_setting and does NOT
    # converge. Deleting these lines from Nix will not remove them from the
    # live cluster -- backing them out needs an explicit
    # `ALTER ROLE mcp RESET <setting>;` by hand.
    extraSql = [
      "GRANT pg_read_all_data TO mcp;"
      "ALTER ROLE mcp SET default_transaction_read_only = on;"
    ];
    # Tighter than the cluster defaults in every direction. This is the only
    # role that gets bounds STRICTER than global rather than looser.
    timeouts = {
      statement_timeout = "'30s'";
      lock_timeout = "'5s'";
      idle_in_transaction_session_timeout = "'30s'";
      transaction_timeout = "'1min'";
      idle_session_timeout = "'10min'";
    };
  };

  # atticd on the cache host. See the ordering gotcha on mkRolePasswordUnit.
  #
  # migrationRoleTimeouts (below) exempts a role from the three cluster
  # defaults that can abort work mid-flight. Every service role here runs its
  # own schema migrations on connect or at startup -- sea-orm for atticd, xorm
  # for forgejo, alembic for romm/hofvarpnir -- and a migration on a 78-IOPS
  # HDD pool legitimately outruns statement_timeout, takes ACCESS EXCLUSIVE
  # locks that outrun lock_timeout, and wraps the whole thing in one
  # transaction that outruns transaction_timeout. Bounding any of those turns
  # a slow deploy into a service that will not start.
  #
  # idle_in_transaction_session_timeout is deliberately NOT exempted: it is the
  # one pathology that compounds (a pinned xmin horizon blocks autovacuum, and
  # the resulting bloat costs IOPS this pool does not have), and no correct
  # client idles two minutes inside an open transaction.
  systemd.services.postgresql-attic-password = mkRolePasswordUnit {
    role = "attic";
    description = "Set attic PostgreSQL user password";
    secret = config.age.secrets.attic-db-password;
    timeouts = migrationRoleTimeouts;
  };

  # terraform additionally needs idle_session_timeout off: the `pg` backend
  # takes its state lock as a SESSION-level advisory lock and then sits idle
  # for the whole plan/apply while it talks to the Proxmox API. Reaping the
  # session would drop the lock mid-apply.
  systemd.services.postgresql-terraform-password = mkRolePasswordUnit {
    role = "terraform";
    description = "Set Terraform PostgreSQL user password";
    secret = config.age.secrets.terraform-state-db-password;
    timeouts = migrationRoleTimeouts // {idle_session_timeout = "0";};
  };

  systemd.services.postgresql-forgejo-password = mkRolePasswordUnit {
    role = "forgejo";
    description = "Set Forgejo PostgreSQL user password";
    secret = config.age.secrets.forgejo-db-password;
    timeouts = migrationRoleTimeouts;
  };

  systemd.services.postgresql-romm-password = mkRolePasswordUnit {
    role = "romm";
    description = "Set RomM PostgreSQL user password";
    secret = config.age.secrets.romm-db-password;
    timeouts = migrationRoleTimeouts;
  };

  systemd.services.postgresql-hofvarpnir-password = mkRolePasswordUnit {
    role = "hofvarpnir";
    description = "Set hofvarpnir PostgreSQL user password";
    secret = config.age.secrets.hofvarpnir-db-password;
    timeouts = migrationRoleTimeouts;
  };

  # Set the postgres superuser password from agenix. The `postgres` role is
  # created by initdb, not by ensureUsers, so this one never actually raced —
  # but it orders on postgresql-setup.service anyway for consistency with the
  # setters above. The unit is named ...-superuser-password but ALTERs the role
  # `postgres`; do not rename the unit to match the role, or systemd sees a new
  # unit and leaves the old one running.
  #
  # postgres is exempted from EVERY abort-y bound, including
  # idle_in_transaction_session_timeout. It is what runs the nightly pg_dump of
  # six databases (the postgresqlBackup-* units are User=postgres), the
  # prometheus exporter (runAsLocalSuperUser), pgbouncer-userlist, and any
  # manual maintenance. pg_dump holds one long transaction and can idle inside
  # it between fetches, and on this pool a dump legitimately runs for minutes;
  # a global bound reaching it means silent backup failure, which is the worst
  # possible thing to discover late.
  systemd.services.postgresql-superuser-password = mkRolePasswordUnit {
    role = "postgres";
    description = "Set postgres superuser password";
    secret = config.age.secrets.postgres-superuser-password;
    timeouts =
      migrationRoleTimeouts
      // {
        idle_session_timeout = "0";
        idle_in_transaction_session_timeout = "0";
      };
  };

  # Backup configuration.
  #
  # The database list is DERIVED from ensureDatabases rather than hand-written.
  # The hand-written list had silently drifted: `attic` (atticd's index --
  # atticd will not start without it, sea-orm runs migrations against it at
  # startup) was never dumped at all, from the day it was added. Deriving it
  # means a future ensureDatabases entry is backed up by construction instead
  # of by remembering to edit two lists -- and a REMOVED one stops being dumped
  # by construction too, which is how `appuser` left without leaving a stale
  # backup unit behind.
  #
  # `forgejo` is the one deliberate exclusion, and it is NOT the drift above:
  # the forgejo database on THIS host is an empty leftover. Forgejo leaves
  # services.forgejo.database.createDatabase at its default of true (see
  # hosts/forgejo/configuration.nix), so it provisions and uses a LOCAL
  # postgres over its unix socket, and dumps that real database itself at
  # 02:30. Dumping the empty one here spent 78-IOPS disk time on a bare schema
  # every night.
  services.postgresqlBackup = {
    enable = true;
    databases = lib.subtractLists ["forgejo"] config.services.postgresql.ensureDatabases;
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

  # Create pgbouncer auth file with postgres user.
  # Orders after postgresql-superuser-password, not just postgresql.service:
  # the script reads the postgres role's scram hash out of pg_authid, and that
  # hash is written by the superuser-password setter. Racing it is not a hard
  # failure — the script falls back to an empty userlist and pgbouncer switches
  # to auth_query — so the symptom is silent, not a failed unit.
  systemd.services.pgbouncer-userlist = {
    description = "Generate PgBouncer userlist";
    wantedBy = ["pgbouncer.service"];
    before = ["pgbouncer.service"];
    after = ["postgresql-superuser-password.service"];
    requires = ["postgresql-superuser-password.service"];
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

  # pgadmin's ExecStartPre (`pgadmin4-cli setup-db`) needs far longer than
  # systemd's default 90s TimeoutStartSec on this host, so the unit failed on
  # essentially every deploy — always killed at exactly 90s, always in start-pre.
  #
  # It is not waiting on anything: pgAdmin's own config database is internal
  # SQLite, so setup-db never contacts PostgreSQL. It is simply IO-bound. Merely
  # loading the CLI (`pgadmin4-cli --help`, which does no database work at all)
  # takes ~48s here — 1.7s of it user CPU, the rest waiting on the ~10k files of
  # the pgadmin closure coming off the 2-HDD zfs_pool (~78 IOPS cluster-wide).
  # Add any concurrent IO — a colmena apply, an attic push — and 90s is gone.
  #
  # Raising the timeout is the honest fix: the work genuinely takes this long,
  # and it only runs at startup. It is not masking a hang.
  systemd.services.pgadmin.serviceConfig.TimeoutStartSec = "10min";

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
      # 6432 (pgbouncer) is deliberately absent: services.pgbouncer above binds
      # listen_addr = 127.0.0.1, so nothing off-box can reach it. The rule only
      # advertised a port that always refuses.
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
