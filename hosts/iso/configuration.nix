{
  lib,
  modulesPath,
  ...
}: {
  # Bootstrap image: no central log shipping. It has no route to
  # loki.homelab.local and no step-ca trust, so fluent-bit would only fail in a
  # loop. common.nix sets this with mkDefault precisely so images can opt out.
  services.loki-logs.enable = false;

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

  # sshd's MaxAuthTries default of 6 is too low for this image's whole purpose.
  # nixos-anywhere is driven from a workstation whose ssh-agent typically holds
  # several keys (amadeus@wotan, radicle, two hermes-bot), ssh offers them one
  # at a time, and nixos-anywhere adds a throwaway key of its own -- so the
  # server hangs up before the right key is necessarily reached. The install
  # then dies with "Received disconnect ... Too many authentication failures",
  # which reads like an unreachable or broken target even though the machine is
  # perfectly healthy. Cost a long diagnosis on 2026-09-09.
  #
  # Client-side workarounds do not hold: `--ssh-option IdentitiesOnly=yes` never
  # reaches the ssh-copy-id call nixos-anywhere makes, and the agent cannot just
  # be turned off because the key it holds is passphrase-protected. Raising the
  # limit on the installer is the fix that actually sticks. This is a live
  # medium with no persistent state, so a higher limit costs nothing.
  services.openssh.settings.MaxAuthTries = 20;

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
