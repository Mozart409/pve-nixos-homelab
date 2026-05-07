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
    ./garage
    ./attic
  ];

  networking.hostName = "homelab-cache";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.175";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-cache.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        # Attic binary cache API
        handle /api/* {
          reverse_proxy localhost:8080
        }

        # Attic cache endpoints
        handle /_nix-cache-info {
          reverse_proxy localhost:8080
        }

        handle /*.narinfo {
          reverse_proxy localhost:8080
        }

        handle /nar/* {
          reverse_proxy localhost:8080
        }

        # Garage S3 API
        handle /s3/* {
          uri strip_prefix /s3
          reverse_proxy localhost:3900
        }

        handle {
          respond "OK" 200
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."cache.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        # Attic binary cache API
        handle /api/* {
          reverse_proxy localhost:8080
        }

        # Attic cache endpoints
        handle /_nix-cache-info {
          reverse_proxy localhost:8080
        }

        handle /*.narinfo {
          reverse_proxy localhost:8080
        }

        handle /nar/* {
          reverse_proxy localhost:8080
        }

        # Garage S3 API
        handle /s3/* {
          uri strip_prefix /s3
          reverse_proxy localhost:3900
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
      80 # HTTP
      443 # HTTPS (Caddy)
      3900 # Garage S3 API
      3901 # Garage RPC
      3902 # Garage Admin API
      8080 # Attic
      9100 # Node exporter
    ];
  };
}
