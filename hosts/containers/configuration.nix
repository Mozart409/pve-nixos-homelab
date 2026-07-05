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
    ../../modules/podman.nix
    ./uptime-forge
    ./albyhub
    ./open-webui
    ./searxng
    ./axon-gateway
    ./pbsmcp
    ./pgmcp
    ./homelab-dashboard
    ./romm
    # Harbor moved to dedicated VM (hosts/harbor)
  ];

  networking.hostName = "homelab-containers";

  # Disable IPv6 - LXC container doesn't have proper IPv6 routing
  # which breaks Tailscale connections preferring IPv6
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.149";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Prometheus exporters
  services.prometheus = {
    exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
    };
    # Postgres exporter is configured in ./uptime-forge/default.nix
    # because it needs access to agenix secrets for the connection string
  };

  # Open WebUI now lives in ./open-webui (listens on localhost:8088)

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-containers.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle /uptime-forge* {
          reverse_proxy localhost:3000
        }

        # Open WebUI is a SvelteKit SPA with a build-time base path of "/",
        # so it must be served at the host root (not a subpath). It is the
        # catch-all here; uptime-forge keeps its own /uptime-forge prefix above.
        handle {
          reverse_proxy localhost:8088
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."containers.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle /uptime-forge* {
          reverse_proxy localhost:3000
        }

        # Open WebUI is a SvelteKit SPA with a build-time base path of "/",
        # so it must be served at the host root (not a subpath). It is the
        # catch-all here; uptime-forge keeps its own /uptime-forge prefix above.
        handle {
          reverse_proxy localhost:8088
        }
      '';
    };

    # AlbyHub on its own hostname (SPA expects to be served at root)
    virtualHosts."albyhub.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8080
      '';
    };

    # SearXNG on its own hostname so off-host clients (e.g. hermes-agent's
    # web_search backend) can reach it. SearXNG binds 127.0.0.1:8089, so Caddy
    # — running on this host — is the only thing that proxies to it.
    virtualHosts."searxng.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8089
      '';
    };

    # axon-gateway MCP gateway. The container binds 127.0.0.1:8091, so Caddy is
    # the only thing that proxies to it. Agents connect at
    # https://axon.homelab.local/mcp (step-ca TLS, trusted on any homelab host).
    virtualHosts."axon.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8091
      '';
    };

    # pbsmcp-server (Proxmox Backup Server MCP). The container binds
    # 127.0.0.1:8093, so Caddy is the only thing that proxies to it. Clients
    # (and axon-gateway) connect at https://pbs-mcp.homelab.local/mcp.
    virtualHosts."pbs-mcp.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8093
      '';
    };

    # pgmcp-server (PostgreSQL MCP). The container binds 127.0.0.1:8094, so
    # Caddy is the only thing that proxies to it. Clients (and axon-gateway)
    # connect at https://pg-mcp.homelab.local/mcp.
    virtualHosts."pg-mcp.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8094
      '';
    };

    # homelab-dashboard. Binds 127.0.0.1:8084 (see ./homelab-dashboard), so
    # Caddy is the only thing that proxies to it. Served at its own hostname.
    virtualHosts."dashboard.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8084
      '';
    };

    # RomM (ROM manager). Binds 127.0.0.1:8095 (see ./romm), so Caddy is the only
    # thing that proxies to it. RomM is a root-served SPA (no URL subpath
    # support), so it gets its own hostname. The Pocket ID OIDC callback is
    # https://romm.homelab.local/api/oauth/openid.
    virtualHosts."romm.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8095
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
      80 # HTTP
      443 # HTTPS (Caddy)
      3000 # Uptime Forge
      5444 # TimescaleDB (external access)
      8080 # AlbyHub
      9100 # Node exporter
      9187 # Postgres exporter
    ];
  };
}
