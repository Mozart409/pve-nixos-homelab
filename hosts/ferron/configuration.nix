{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
  ];

  networking.hostName = "ferron";

  # Ferron specific configuration
  # This could be a general-purpose server or specific service host
  # Add your ferron-specific services here

  # Example: could be used as a container host
  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  # Firewall rules for ferron
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443]; # SSH
  };

  # Additional packages for ferron
  environment.systemPackages = with pkgs; [
    podman
    podman-compose
  ];
}
