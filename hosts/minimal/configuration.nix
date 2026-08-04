{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    # XFS, not the btrfs disko-config.nix. This is the layout every new VM gets:
    # `deploy-minimal` is the only step that ever runs disko, so whatever is
    # imported here is the filesystem the host keeps for life -- a later
    # `colmena apply` never repartitions. Every VM disk is a zvol on the host's
    # ZFS pool, and btrfs on top stacks a second CoW (and a second compression)
    # layer on it. See modules/disko-xfs.nix.
    ../../modules/disko-xfs.nix
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
