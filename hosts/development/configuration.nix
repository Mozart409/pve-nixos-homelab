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
    ../../modules/podman.nix
  ];

  networking.hostName = "homelab-development";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.184";
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

  # Podman (+ Docker compat, container DNS) comes from ../../modules/podman.nix

  networking.firewall = {
    enable = true;
    # podman+ = every podman bridge (podman0 plus any per-experiment network).
    # Without trusting them the host firewall drops container -> aardvark-dns
    # traffic, so containers can't resolve each other. See harbor's podman1 note.
    trustedInterfaces = ["tailscale0" "podman+"];
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
}
