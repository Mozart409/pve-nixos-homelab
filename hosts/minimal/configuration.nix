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

  # keep-sorted start

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22 # SSH
    ];
    networking.hostName = "homelab-minimal";
    # Use DHCP for easy testing
    networking.useDHCP = lib.mkForce true;
  };
  # keep-sorted end
}
