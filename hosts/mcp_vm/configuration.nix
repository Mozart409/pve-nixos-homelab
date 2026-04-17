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
          reverse_proxy http://localhost:3000
        }
      '';
    };
  };

  age.secrets.homeassistant-token = {
    file = ../../secrets/homeassistant-token.age;
  };

  services.hamcp = {
    enable = true;
    haUrl = "https://homeassistant.dropbear-butterfly.ts.net";
    haTokenFile = config.age.secrets.homeassistant-token.path;
    port = 3000;
    openFirewall = true;
  };

  systemd.services.hamcp = {
    wants = ["agenix.target"];
    after = ["agenix.target"];
    # Override script to strip trailing newline from token
    script = lib.mkForce ''
      export HA_TOKEN="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/ha-token")"
      exec ${config.services.hamcp.package}/bin/mcp
    '';
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
