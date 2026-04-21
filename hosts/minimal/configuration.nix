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

  networking = {
    hostName = "homelab-minimal";
    useDHCP = lib.mkForce true; # Use DHCP for easy testing
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };
  };
}
