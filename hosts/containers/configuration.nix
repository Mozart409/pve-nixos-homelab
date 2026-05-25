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
    # Harbor moved to dedicated VM (hosts/harbor)
  ];

  networking.hostName = "homelab-containers";

  # open-webui ships under a non-free license; required for the uptime-forge stack
  # Disabled along with services.open-webui below — re-enable when open-webui is in use again.
  # nixpkgs.config.allowUnfree = true;

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

  # Open WebUI - LLM chat interface (external APIs only)
  # TEMPORARILY DISABLED: nixpkgs open-webui-0.9.5 frontend build is broken
  # (bits-ui peer dep '@internationalized/date' missing in derivation).
  # Re-enable once nixpkgs ships a fixed open-webui package.
  # services.open-webui = {
  #   enable = true;
  #   port = 8080;
  #   environment = {
  #     WEBUI_AUTH = "true";
  #     ENABLE_OLLAMA_API = "false";
  #     ENABLE_OPENAI_API = "true";
  #     # OIDC authentication
  #     ENABLE_OAUTH_SIGNUP = "true";
  #     OAUTH_PROVIDER_NAME = "Pocket ID";
  #     OPENID_PROVIDER_URL = "https://pocketid.dropbear-butterfly.ts.net/.well-known/openid-configuration";
  #     OAUTH_SCOPES = "openid email profile groups";
  #     ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
  #     OAUTH_ROLES_CLAIM = "groups";
  #     OAUTH_ADMIN_ROLES = "admins";
  #   };
  #   # Secrets file should contain:
  #   # OAUTH_CLIENT_ID=...
  #   # OAUTH_CLIENT_SECRET=...
  #   # OPENAI_API_KEY=sk-...  (optional)
  #   environmentFile = config.age.secrets.open-webui-env.path;
  # };

  # Open WebUI secrets
  # age.secrets.open-webui-env = {
  #   file = ../../secrets/open-webui-env.age;
  #   owner = "open-webui";
  #   group = "open-webui";
  # };

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

        # handle /open-webui* {
        #   uri strip_prefix /open-webui
        #   reverse_proxy localhost:8080
        # }

        handle {
          respond "OK" 200
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

        # handle /open-webui* {
        #   uri strip_prefix /open-webui
        #   reverse_proxy localhost:8080
        # }

        handle {
          respond "OK" 200
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
