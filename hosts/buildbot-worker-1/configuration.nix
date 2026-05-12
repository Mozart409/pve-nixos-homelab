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

  networking.hostName = "homelab-buildbot-worker-1";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.179";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Buildbot secrets
  age.secrets.buildbot-worker-password = {
    file = ../../secrets/buildbot-worker-password.age;
    owner = "bbworker";
    group = "bbworker";
  };

  # Buildbot Worker
  services.buildbot-worker = {
    enable = true;
    masterUrl = "192.168.2.177:9989";
    workerUser = "worker-1";
    workerPassFile = config.age.secrets.buildbot-worker-password.path;
    buildbotDir = "/var/lib/buildbot-worker";
    packages = with pkgs; [
      # Build tools
      git
      nix
      nixpkgs-fmt
      alejandra
      # Common build dependencies
      gcc
      gnumake
      pkg-config
      openssl
      # Container tools
      podman
      skopeo
    ];
  };

  # Create buildbot-worker directory with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/buildbot-worker 0750 bbworker bbworker -"
  ];

  # Ensure directory exists before buildbot-worker starts
  systemd.services.buildbot-worker.serviceConfig.StateDirectory = "buildbot-worker";
  systemd.services.buildbot-worker.serviceConfig.StateDirectoryMode = "0750";

  # Allow bbworker to use Nix
  nix.settings.trusted-users = ["bbworker"];

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS (for health checks)
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-buildbot-worker-1.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          respond "Buildbot Worker 1 OK" 200
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."buildbot-worker-1.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          respond "Buildbot Worker 1 OK" 200
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
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    htop
    ncdu
  ];
}
