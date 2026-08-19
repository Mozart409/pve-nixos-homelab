{
  config,
  lib,
  pkgs,
  homelab-mcp,
  ...
}: let
  mcpPackages = homelab-mcp.packages.${pkgs.stdenv.hostPlatform.system};

  # Restart nonce for the secret-consuming MCP servers.
  #
  # agenix rewrites /run/agenix/<name> in place, so re-encrypting a secret leaves
  # the generated unit file byte-identical. switch-to-configuration restarts a
  # unit only when its definition changes, so it sees nothing to do and the
  # service keeps serving with the credential it read at startup — the symptom is
  # a redeployed token that still gets 401.
  #
  # Bump this string whenever a secret's *content* changes; that changes
  # restartTriggers -> the unit definition -> a restart on the next colmena apply.
  secretNonce = "2026-08-06-wpmcp-token";

  # Caddy vhost template: step-ca TLS + reverse proxy to a loopback MCP server.
  mkMcpVhost = port: {
    extraConfig = ''
      tls {
        ca https://ca.homelab.local:8443/acme/acme/directory
      }

      handle {
        reverse_proxy http://localhost:${toString port}
      }
    '';
  };

  # Postgres MCP servers on the `database` host: one instance per database.
  #
  # pgmcp builds a single connection pool from PG_DATABASE_URL and no tool takes
  # a database argument (`database_size` is literally `SELECT
  # current_database()`), so a Postgres connection's one-database scope is the
  # server's scope too — reaching N databases means N instances. They all share
  # the cluster-wide read-only `mcp` role defined on the database host; only the
  # trailing /<db> of the connection URL differs.
  #
  # `buildbot` is deliberately absent: its master/worker VMs are gone and the
  # database/role were dropped from the database host.
  #
  # `appuser` (was 8086) is absent for the same reason: a scratch database with
  # no writer, whose only reader was this pgmcp instance. Database, role and
  # instance were all dropped. 8086 is free to reuse.
  homelabDatabases = {
    appdb = 8085;
    terraform = 8087;
    forgejo = 8088;
    romm = 8089;
    hofvarpnir = 8090;
  };

  pgVhostName = db: "pg-${db}-mcp.homelab.local";
  pgUnitName = db: "pgmcp-${db}-server";
  pgSecretName = db: "pg-mcp-${db}-url";

  mcpServerUnits =
    map (name: {
      unit = "${name}.service";
      job = name;
    }) [
      "pbsmcp-server"
      "pgmcp-server"
      "prommcp-server"
      "lokimcp-server"
      "hamcp-server"
      "wpmcp-server"
    ]
    ++ map (db: {
      unit = "${pgUnitName db}.service";
      job = pgUnitName db;
    }) (builtins.attrNames homelabDatabases);
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
    ../../modules/loki-logs.nix
  ];

  networking.hostName = "homelab-mcp";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.152";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Ship all homelab-mcp server journals to the central Loki.
  services.loki-logs = {
    enable = true;
    units = mcpServerUnits;
  };

  # Caddy reverse proxy: one vhost per MCP server. All servers bind loopback,
  # so Caddy is the only way in. The MCP endpoint is at /mcp on each vhost.
  services.caddy = {
    enable = true;

    virtualHosts =
      {
        # Tailscale hostname (kept for backwards compatibility -> Home Assistant MCP)
        "homelab-mcp.dropbear-butterfly.ts.net" = {
          extraConfig = ''
            tls {
              get_certificate tailscale
            }

            handle {
              reverse_proxy http://localhost:8084
            }
          '';
        };

        # Home Assistant MCP keeps the historical mcp.homelab.local name so the
        # axon-gateway "hamcp" backend URL stays valid.
        "mcp.homelab.local" = mkMcpVhost 8084;
        "pbs-mcp.homelab.local" = mkMcpVhost 8080;
        # Renamed from pg-mcp.homelab.local now that several Postgres MCP
        # instances exist; this one is the uptime-forge TimescaleDB.
        "pg-uptime-mcp.homelab.local" = mkMcpVhost 8081;
        "prom-mcp.homelab.local" = mkMcpVhost 8082;
        "loki-mcp.homelab.local" = mkMcpVhost 8083;
        "wp-mcp.homelab.local" = mkMcpVhost 8091;
      }
      # One vhost per database on the `database` host.
      // lib.mapAttrs' (db: port: lib.nameValuePair (pgVhostName db) (mkMcpVhost port)) homelabDatabases;
  };

  age.secrets =
    {
      homeassistant-token = {
        file = ../../secrets/homeassistant-token.age;
      };
      pbs-mcp-token = {
        file = ../../secrets/pbs-mcp-token.age;
      };
      pg-mcp-uptime-url = {
        file = ../../secrets/pg-mcp-uptime-url.age;
      };
      woodpecker-mcp-token = {
        file = ../../secrets/woodpecker-mcp-token.age;
      };
    }
    # postgres://mcp:<pw>@database.homelab.local:5432/<db> — same read-only role
    # and password for every entry, one database each.
    // lib.mapAttrs' (db: _:
      lib.nameValuePair (pgSecretName db) {
        file = ../../secrets/${pgSecretName db}.age;
      })
    homelabDatabases;

  # Every MCP server from the homelab-mcp-servers monorepo, as hardened native
  # systemd services (DynamicUser, secrets via LoadCredential). The five named
  # instances below map 1:1 onto the workspace binaries; the generated
  # pgmcp-<db>-server set reuses the pgmcp binary via `serverType`.
  services.homelab-mcp.servers =
    {
      pbsmcp-server = {
        enable = true;
        package = mcpPackages.pbsmcp-server;
        host = "https://pbs.dropbear-butterfly.ts.net/";
        tokenFile = config.age.secrets.pbs-mcp-token.path;
        bind = "127.0.0.1:8080";
        allowedHosts = ["pbs-mcp.homelab.local" "localhost" "127.0.0.1"];
      };

      # uptime-forge TimescaleDB (on the containers host).
      pgmcp-server = {
        enable = true;
        package = mcpPackages.pgmcp-server;
        # The full connection URL (with password) travels via tokenFile ->
        # PG_DATABASE_URL; no host option needed.
        tokenFile = config.age.secrets.pg-mcp-uptime-url.path;
        bind = "127.0.0.1:8081";
        allowedHosts = ["pg-uptime-mcp.homelab.local" "localhost" "127.0.0.1"];
      };

      prommcp-server = {
        enable = true;
        package = mcpPackages.prommcp-server;
        # Prometheus on the otel host; port 9090 is opened in its firewall.
        host = "http://otel.homelab.local:9090";
        bind = "127.0.0.1:8082";
        allowedHosts = ["prom-mcp.homelab.local" "localhost" "127.0.0.1"];
      };

      lokimcp-server = {
        enable = true;
        package = mcpPackages.lokimcp-server;
        host = "http://otel.homelab.local:3100";
        bind = "127.0.0.1:8083";
        allowedHosts = ["loki-mcp.homelab.local" "localhost" "127.0.0.1"];
      };

      hamcp-server = {
        enable = true;
        package = mcpPackages.hamcp-server;
        host = "https://homeassistant.dropbear-butterfly.ts.net";
        tokenFile = config.age.secrets.homeassistant-token.path;
        bind = "127.0.0.1:8084";
        allowedHosts = [
          "mcp.homelab.local"
          "homelab-mcp.dropbear-butterfly.ts.net"
          "localhost"
          "127.0.0.1"
        ];
      };

      # Woodpecker CI, which runs on its own host. `ci.homelab.local` is baked
      # into Woodpecker's OAuth redirect and every webhook it registers, so it
      # is permanent — see AGENTS.md §6.
      wpmcp-server = {
        enable = true;
        package = mcpPackages.wpmcp-server;
        host = "https://ci.homelab.local";
        tokenFile = config.age.secrets.woodpecker-mcp-token.path;
        # wpmcp's own default is 8085, but that port is already the appdb pgmcp
        # instance here, so this one takes the next free port instead.
        bind = "127.0.0.1:8091";
        allowedHosts = ["wp-mcp.homelab.local" "localhost" "127.0.0.1"];
      };
    }
    # One pgmcp instance per database on the `database` host. serverType pins the
    # PG_* env prefix — without it the module would derive PGMCP-<DB>-SERVER from
    # the instance name and the server would find no config at all.
    // lib.mapAttrs' (db: port:
      lib.nameValuePair (pgUnitName db) {
        enable = true;
        serverType = "pgmcp-server";
        package = mcpPackages.pgmcp-server;
        tokenFile = config.age.secrets.${pgSecretName db}.path;
        bind = "127.0.0.1:${toString port}";
        allowedHosts = [(pgVhostName db) "localhost" "127.0.0.1"];
      })
    homelabDatabases;

  systemd.services =
    # Secret-consuming servers must wait for agenix to place the credentials.
    lib.genAttrs (["pbsmcp-server" "pgmcp-server" "hamcp-server" "wpmcp-server"]
      ++ map pgUnitName (builtins.attrNames homelabDatabases)) (_: {
      wants = ["agenix.target"];
      after = ["agenix.target"];
      # See secretNonce above: forces a restart when a secret is re-encrypted.
      restartTriggers = [secretNonce];
    })
    // {
      # Give Caddy access to Tailscale socket for cert fetching
      caddy = {
        after = ["tailscaled.service"];
        wants = ["tailscaled.service"];
        serviceConfig.BindPaths = ["/run/tailscale/tailscaled.sock"];
      };
    };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
  };

  environment.systemPackages = with pkgs; [
  ];
}
