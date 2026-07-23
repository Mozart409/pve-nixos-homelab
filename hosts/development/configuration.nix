{
  config,
  lib,
  pkgs,
  herdr,
  ...
}: let
  herdrPkgs = herdr.packages.${pkgs.stdenv.hostPlatform.system};
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/podman.nix
    ../../modules/moshi-hook-user.nix
    ../../modules/coding-harness.nix
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

  # Moshi pairing token (plain raw text, NOT KEY=value — read directly by
  # modules/moshi-hook-user.nix's pair script). Owned by amadeus so
  # moshi-hook-setup (User=amadeus) can read it.
  age.secrets.moshi-device-id = {
    file = ../../secrets/moshi-device-id.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Axon MCP gateway bearer token (file contains AXON_GATEWAY_TOKEN=...).
  # Owned by amadeus: modules/coding-harness.nix sources it directly into
  # every interactive login shell (environment.interactiveShellInit) so
  # Claude Code / opencode can expand it from their MCP config at runtime.
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Development tools for experiments
  environment.systemPackages = with pkgs;
    [
      # keep-sorted start
      bat
      claude-code
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
      opencode
      ripgrep
      tmux
      wget
      yq
      # keep-sorted end
    ]
    ++ [herdrPkgs.herdr];
}
