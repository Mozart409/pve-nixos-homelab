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
  secretNonce = "2026-09-14-otel-query-token";

  # Since 2026-09-14 no MCP server has a vhost. They all bind loopback and the
  # only client is axon-gateway (./axon-gateway), which now runs on THIS host
  # with host networking and dials them on 127.0.0.1 directly. Before that
  # every backend had its own *-mcp.homelab.local Caddy vhost with no
  # authentication at all -- the audit that day confirmed `initialize` +
  # `run_query` / `call_service` worked from any LAN or tailnet address,
  # bypassing the gateway's bearer token entirely. Caddy on this host now
  # serves exactly one thing: the gateway.
  #
  # The old vhost keys (both private zones per name, one ACME order per name,
  # the badNonce lockstep that caused -- see todo/dns-cache-ssd-xfs-
  # migration.md D.5) are gone with it, as are their A/PTR records in
  # hosts/dns/configuration.nix and the blackbox mcp_probe job on otel.
  loopbackOnly = ["localhost" "127.0.0.1"];

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
  #
  # The uptime-forge TimescaleDB instance (`pgmcp-server`, 8081, vhost
  # pg-uptime-mcp, secret pg-mcp-uptime-url) went on 2026-09-12 when
  # uptime-forge was retired on the containers host. That database lived in
  # a podman volume there, not on the `database` host, so it never belonged
  # in this attrset. The secret file is still in secrets/ (unreferenced);
  # 8081 is free to reuse.
  homelabDatabases = {
    appdb = 8085;
    terraform = 8087;
    forgejo = 8088;
    romm = 8089;
    hofvarpnir = 8090;
  };

  pgUnitName = db: "pgmcp-${db}-server";
  pgSecretName = db: "pg-mcp-${db}-url";

  mcpServerUnits =
    [
      {
        unit = "podman-axon-gateway.service";
        job = "axon-gateway";
      }
    ]
    ++ map (name: {
      unit = "${name}.service";
      job = name;
    }) [
      "pbsmcp-server"
      "prommcp-server"
      "lokimcp-server"
      "hamcp-server"
      "wpmcp-server"
      "alertmanagermcp-server"
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
    ../../modules/fluent-bit.nix
    ../../modules/podman.nix
    ../../modules/caddy-http3.nix
    ./axon-gateway
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

  # Caddy serves exactly one thing on this host: axon-gateway. Its vhosts live
  # next to the container in ./axon-gateway (they are the only consumer of its
  # port); the MCP servers below have no vhost at all.
  services.caddy.enable = true;

  age.secrets =
    {
      homeassistant-token = {
        file = ../../secrets/homeassistant-token.age;
      };
      pbs-mcp-token = {
        file = ../../secrets/pbs-mcp-token.age;
      };
      woodpecker-mcp-token = {
        file = ../../secrets/woodpecker-mcp-token.age;
      };
      # Read-side bearer for the prometheus/loki/alertmanager vhosts on otel
      # (see hosts/otel/configuration.nix). Bare token; each server exports it
      # as <PREFIX>_TOKEN from LoadCredential.
      otel-query-token = {
        file = ../../secrets/otel-query-token.age;
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
  # systemd services (DynamicUser, secrets via LoadCredential). The named
  # instances below map 1:1 onto the workspace binaries; the generated
  # pgmcp-<db>-server set is the only user of the pgmcp binary, via `serverType`.
  services.homelab-mcp.servers =
    {
      pbsmcp-server = {
        enable = true;
        package = mcpPackages.pbsmcp-server;
        host = "https://pbs.dropbear-butterfly.ts.net/";
        tokenFile = config.age.secrets.pbs-mcp-token.path;
        bind = "127.0.0.1:8080";
        allowedHosts = loopbackOnly;
      };

      prommcp-server = {
        enable = true;
        package = mcpPackages.prommcp-server;
        # Through otel's Caddy with the query token: raw 9090 is closed since
        # 2026-09-14.
        host = "https://prometheus.homelab.local";
        tokenFile = config.age.secrets.otel-query-token.path;
        bind = "127.0.0.1:8082";
        allowedHosts = loopbackOnly;
      };

      lokimcp-server = {
        enable = true;
        package = mcpPackages.lokimcp-server;
        host = "https://loki.homelab.local";
        tokenFile = config.age.secrets.otel-query-token.path;
        bind = "127.0.0.1:8083";
        allowedHosts = loopbackOnly;
      };

      hamcp-server = {
        enable = true;
        package = mcpPackages.hamcp-server;
        host = "https://homeassistant.dropbear-butterfly.ts.net";
        tokenFile = config.age.secrets.homeassistant-token.path;
        bind = "127.0.0.1:8084";
        allowedHosts = loopbackOnly;
      };

      # Woodpecker CI, which runs on its own host. `ci.homelab.local` is baked
      # into Woodpecker's OAuth redirect and every webhook it registers, so it
      # is permanent — see AGENTS.md §6.
      wpmcp-server = {
        enable = true;
        package = mcpPackages.wpmcp-server;
        host = "https://ci.homelab.local";
        tokenFile = config.age.secrets.woodpecker-mcp-token.path;
        bind = "127.0.0.1:8091";
        allowedHosts = loopbackOnly;
      };

      alertmanagermcp-server = {
        enable = true;
        package = mcpPackages.alertmanagermcp-server;
        extraEnv.ALERTMANAGER_HOST = "https://alertmanager.homelab.internal";
        tokenFile = config.age.secrets.otel-query-token.path;
        bind = "127.0.0.1:8086";
        allowedHosts = loopbackOnly;
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
        allowedHosts = loopbackOnly;
      })
    homelabDatabases;

  systemd.services =
    # Secret-consuming servers must wait for agenix to place the credentials.
    lib.genAttrs (["pbsmcp-server" "hamcp-server" "wpmcp-server" "prommcp-server" "lokimcp-server" "alertmanagermcp-server"]
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
