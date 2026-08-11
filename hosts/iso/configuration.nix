{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    # Verified present in the pinned nixpkgs. Reached via modulesPath, the same
    # way hosts/rpi/configuration.nix imports the sd-card installer module --
    # the nixpkgs flake exposes no nixosModules attribute for this.
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    # Brings the amadeus account + its SSH keys, so the booted ISO is reachable
    # immediately. Deliberately NOT modules/disko-xfs.nix: that pins a Proxmox
    # /dev/disk/by-id path, and a live medium has no persistent layout anyway.
    ../../modules/common.nix
  ];

  networking = {
    hostName = lib.mkForce "homelab-iso";
    # The ISO boots on whatever is in front of it, so DHCP rather than
    # common.nix's static-IP defaults, and no homelab resolver -- 192.168.2.145
    # does not exist on a foreign network.
    useDHCP = lib.mkForce true;
    nameservers = lib.mkForce [];
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };
  };

  # Second user, ready to uncomment. Each entry is independent -- own keys, own
  # groups -- which is the point of modules/homelab-users.nix.
  # homelab.users.installer = {
  #   isAdmin = true;
  #   sshKeys = ["ssh-ed25519 AAAA... someone@somewhere"];
  # };

  # The installer profile turns ZFS on by default, which drags the kernel
  # modules into the image for nothing -- this ISO installs onto Proxmox zvols
  # and the guest never touches ZFS itself. Same mkForce the Pi images use.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  isoImage = {
    edition = "homelab";
    volumeID = "NIXOS_HOMELAB";
    makeEfiBootable = true;
    makeUsbBootable = true;
  };
}
