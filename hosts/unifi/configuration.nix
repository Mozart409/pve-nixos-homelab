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

  # Allow unfree packages (required for UniFi controller)
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "unifi-controller"
    ];

  networking.hostName = "homelab-unifi";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.142";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.136" "1.1.1.1"];

  # UniFi Network Controller
  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi;
    openFirewall = true;
  };

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;
    virtualHosts."homelab-unifi.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy https://localhost:8443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        }
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      8080 # Device inform
      8443 # UniFi web UI
      8880 # HTTP portal redirect
      8843 # HTTPS portal redirect
      6789 # Mobile speedtest
    ];
    allowedUDPPorts = [
      3478 # STUN
      10001 # Device discovery
    ];
  };

  environment.systemPackages = with pkgs; [
    unifi
  ];
}
