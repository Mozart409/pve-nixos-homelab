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
  networking.nameservers = ["192.168.2.136" "1.1.1.1"];

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;
    virtualHosts."homelab-mcp.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy https://localhost:3000 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        }
      '';
    };
  };

  age.secrets.homeassistant-token = {
    file = ../../secrets/homeassistant-token.age;
    owner = "hamcp";
  };

  services.hamcp = {
    enable = true;
    haUrl = "http://homeassistant.local:8123";
    haTokenFile = config.age.secrets.homeassistant-token.path;
    port = 3000;
    openFirewall = true;
  };

  systemd.services.hamcp = {
    wants = ["agenix.target"];
    after = ["agenix.target"];
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy = {
    after = ["tailscaled.service"];
    wants = ["tailscaled.service"];
    serviceConfig.BindPaths = ["/run/tailscale/tailscaled.sock"];
  };

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
