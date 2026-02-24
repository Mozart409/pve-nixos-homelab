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
    ../../modules/podman.nix
    ./uptime-forge
    ./harbor
  ];

  networking.hostName = "homelab-containers";

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
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  # Prometheus exporters
  services.prometheus = {
    exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
    };
    # Postgres exporter is configured in ./uptime-forge/default.nix
    # because it needs access to agenix secrets for the connection string
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;
    virtualHosts."homelab-containers.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle_path /uptime-forge* {
          reverse_proxy localhost:3000
        }

        handle_path /harbor* {
          reverse_proxy localhost:8081
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
      3000 # Uptime Forge
      5000 # Harbor registry
      5444 # TimescaleDB (external access)
      8080 # Harbor core API
      8081 # Harbor portal
      9100 # Node exporter
      9187 # Postgres exporter
    ];
  };
}
