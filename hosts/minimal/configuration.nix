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

  networking.hostName = "homelab-minimal";

  # Use DHCP for easy testing
  networking.useDHCP = lib.mkForce true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22 # SSH
    ];
  };
}
