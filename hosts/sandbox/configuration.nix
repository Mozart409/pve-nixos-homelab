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

  networking.hostName = "homelab-sandbox";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.176";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Enable Docker/Podman for container experiments
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      9100 # Node exporter
    ];
  };

  # Development tools for experiments
  environment.systemPackages = with pkgs; [
    # keep-sorted start
    bat
    curl
    delta
    docker-compose
    eza
    fd
    fzf
    git
    htop
    httpie
    jq
    lazygit
    neovim
    ripgrep
    tmux
    wget
    yq
    # keep-sorted end
  ];

  # Add amadeus to docker group
  users.users.amadeus.extraGroups = ["docker" "podman"];
}
