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
    ../../modules/moshi-hook-user.nix
    ../../modules/coding-harness.nix
    ./zeroclaw
  ];

  networking.hostName = "homelab-zeroclaw";

  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.183";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Moshi pairing token (plain raw text, NOT KEY=value — read directly by
  # modules/moshi-hook-user.nix's pair script). Owned by amadeus so
  # moshi-hook-setup (User=amadeus) can read it.
  age.secrets.moshi-device-id = {
    file = ../../secrets/moshi-device-id.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Axon MCP gateway bearer token, sourced into interactive shells by
  # modules/coding-harness.nix (see that module for details).
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Interactive tools for amadeus's own use on this host, separate from the
  # containerized ZeroClaw agent in ./zeroclaw/default.nix (which runs in an
  # OCI container with no host-filesystem presence).
  environment.systemPackages = with pkgs; [claude-code opencode];

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  services.caddy = {
    enable = true;

    virtualHosts."homelab-zeroclaw.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        reverse_proxy localhost:42617
      '';
    };

    virtualHosts."zeroclaw.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:42617
      '';
    };
  };

  services.tailscale.permitCertUid = "caddy";
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
  };
}
