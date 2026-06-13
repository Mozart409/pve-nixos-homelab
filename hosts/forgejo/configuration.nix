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

  networking.hostName = "homelab-forgejo";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.178";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Forgejo Git Forge
  services.forgejo = {
    enable = true;
    stateDir = "/var/lib/forgejo";

    database = {
      type = "postgres";
      host = "192.168.2.134";
      port = 5432;
      name = "forgejo";
      user = "forgejo";
      passwordFile = config.age.secrets.forgejo-db-password.path;
    };

    settings = {
      DEFAULT = {
        APP_NAME = "Homelab Forgejo";
      };

      server = {
        DOMAIN = "forgejo.homelab.local";
        ROOT_URL = "https://homelab-forgejo.dropbear-butterfly.ts.net/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3000;
        SSH_PORT = 2222;
        SSH_LISTEN_PORT = 2222;
        START_SSH_SERVER = true;
      };

      service = {
        DISABLE_REGISTRATION = true;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        ENABLE_NOTIFY_MAIL = false;
      };

      session = {
        COOKIE_SECURE = true;
        PROVIDER = "file";
      };

      log = {
        LEVEL = "Info";
      };

      # OIDC authentication with Pocket-ID
      "oauth2_client" = {
        ENABLE_AUTO_REGISTRATION = true;
        ACCOUNT_LINKING = "auto";
        UPDATE_AVATAR = true;
        USERNAME = "nickname";
      };
    };
  };

  # Forgejo secrets
  age.secrets.forgejo-db-password = {
    file = ../../secrets/forgejo-db-password.age;
    owner = "forgejo";
    group = "forgejo";
  };

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-forgejo.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy localhost:3000
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."forgejo.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          reverse_proxy localhost:3000
        }
      '';
    };

    # Redirect plain HTTP to HTTPS for the local hostname.
    virtualHosts."http://forgejo.homelab.local" = {
      extraConfig = ''
        redir https://{host}{uri} permanent
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
      80 # HTTP (Caddy redirect to HTTPS)
      443 # HTTPS (Caddy)
      2222 # Forgejo SSH
      3000 # Forgejo HTTP
      9100 # Node exporter
    ];
  };
}
