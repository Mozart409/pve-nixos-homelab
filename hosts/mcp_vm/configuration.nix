{
  config,
  lib,
  pkgs,
  homelab-mcp,
  ...
}: let
  mcpPackages = homelab-mcp.packages.${pkgs.stdenv.hostPlatform.system};

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
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
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

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy: one vhost per MCP server. All servers bind loopback,
  # so Caddy is the only way in. The MCP endpoint is at /mcp on each vhost.
  services.caddy = {
    enable = true;

    # Tailscale hostname (kept for backwards compatibility -> Home Assistant MCP)
    virtualHosts."homelab-mcp.dropbear-butterfly.ts.net" = {
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
    virtualHosts."mcp.homelab.local" = mkMcpVhost 8084;
    virtualHosts."pbs-mcp.homelab.local" = mkMcpVhost 8080;
    virtualHosts."pg-mcp.homelab.local" = mkMcpVhost 8081;
    virtualHosts."prom-mcp.homelab.local" = mkMcpVhost 8082;
    virtualHosts."loki-mcp.homelab.local" = mkMcpVhost 8083;
  };

  age.secrets.homeassistant-token = {
    file = ../../secrets/homeassistant-token.age;
  };
  age.secrets.pbs-mcp-token = {
    file = ../../secrets/pbs-mcp-token.age;
  };
  age.secrets.pg-mcp-database-url = {
    file = ../../secrets/pg-mcp-database-url.age;
  };

  # All five MCP servers from the homelab-mcp-servers monorepo, as hardened
  # native systemd services (DynamicUser, secrets via LoadCredential).
  services.homelab-mcp.servers = {
    pbsmcp-server = {
      enable = true;
      package = mcpPackages.pbsmcp-server;
      host = "https://pbs.dropbear-butterfly.ts.net/";
      tokenFile = config.age.secrets.pbs-mcp-token.path;
      bind = "127.0.0.1:8080";
      allowedHosts = ["pbs-mcp.homelab.local" "localhost" "127.0.0.1"];
    };

    pgmcp-server = {
      enable = true;
      package = mcpPackages.pgmcp-server;
      # The full connection URL (with password) travels via tokenFile ->
      # PG_DATABASE_URL; no host option needed.
      tokenFile = config.age.secrets.pg-mcp-database-url.path;
      bind = "127.0.0.1:8081";
      allowedHosts = ["pg-mcp.homelab.local" "localhost" "127.0.0.1"];
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
  };

  systemd.services =
    # Secret-consuming servers must wait for agenix to place the credentials.
    lib.genAttrs ["pbsmcp-server" "pgmcp-server" "hamcp-server"] (_: {
      wants = ["agenix.target"];
      after = ["agenix.target"];
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
