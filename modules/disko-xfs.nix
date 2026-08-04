{lib, ...}: {
  # Single-disk XFS root. Drop-in replacement for modules/disko-config.nix
  # (same GPT layout, same BIOS-boot/GRUB setup) that swaps the btrfs root for
  # XFS. **Prefer this for new VMs on this Proxmox host.**
  #
  # Why not btrfs: every VM disk here is a zvol on the host's `zfs_pool`, so ZFS
  # is already doing copy-on-write, checksumming and compression underneath the
  # guest. btrfs on top stacks a second CoW layer on the first — each guest write
  # is CoW'd by btrfs, and the resulting block write is CoW'd again by ZFS, which
  # multiplies write amplification and fragmentation. It also compresses
  # everything twice (btrfs `compress=zstd` over the pool's own compression):
  # CPU spent re-compressing data ZFS would compress anyway. The penalty scales
  # with how write-heavy the guest is, and `zfs_pool` is two spinning disks
  # (~78 IOPS between them) shared by every VM in the lab.
  #
  # Why XFS over ext4: extent-based allocation plus delayed allocation batches
  # small writes into fewer, larger extents before they reach the zvol, which is
  # what helps when the pool's volblocksize is larger than a 4K guest block. Its
  # journal is also cheaper for metadata-heavy trees. For container hosts
  # specifically, podman's `overlay` driver needs `d_type` — XFS provides it via
  # `ftype=1` (the default for any modern mkfs.xfs, set explicitly below so it is
  # not accidental) and fuse-overlayfs can use XFS reflinks for copy-up, which
  # ext4 cannot.
  #
  # Trade-off: no guest-side snapshots or subvolumes, and XFS grows but never
  # shrinks. Snapshotting is the Proxmox/ZFS layer's job here, so this gives up
  # nothing that was actually in use.
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # Pinned by stable by-id path rather than /dev/sda: enumeration order is
        # not stable inside the nixos-anywhere installer. Encodes the Proxmox
        # scsi index, so this is the OS disk (scsi0) on any VM using this module.
        # A host with extra disks overrides it / adds its own. See
        # modules/disko-jellyfin.nix.
        device = lib.mkDefault "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
        content = {
          type = "gpt";
          partitions = {
            # BIOS boot partition for GRUB (the VM boots seabios, not UEFI)
            bios = {
              size = "1M";
              type = "EF02";
            };
            boot = {
              size = "1G";
              label = "boot";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot";
                mountOptions = ["defaults"];
              };
            };
            # A real partition, not a swapfile: disko-config.nix puts swap on a
            # btrfs subvolume, and XFS swapfiles need a hole-free extent that
            # delayed allocation makes awkward to guarantee. `discardPolicy` lets
            # ZFS reclaim the space on the pool when pages are freed.
            swap = {
              size = "4G";
              label = "swap";
              content = {
                type = "swap";
                discardPolicy = "once";
              };
            };
            root = {
              size = "100%";
              label = "nixos";
              content = {
                type = "filesystem";
                format = "xfs";
                # -f: overwrite any existing signature (reinstall).
                # -n ftype=1: d_type support, required by podman's overlay driver.
                extraArgs = ["-f" "-L" "nixos" "-n" "ftype=1"];
                mountpoint = "/";
                # No `discard`: continuous discard on a zvol issues a TRIM per
                # extent free, which is exactly the small-IO pattern this layout
                # exists to avoid. services.fstrim below batches it weekly instead.
                mountOptions = ["noatime"];
              };
            };
          };
        };
      };
    };
  };

  # Batched TRIM so freed blocks are returned to the pool instead of keeping the
  # zvol permanently inflated. Requires `discard = "on"` on the Proxmox disk
  # (iac/main.tf) to actually reach ZFS.
  services.fstrim = {
    enable = true;
    interval = "weekly";
  };

  # GRUB bootloader configuration
  # Disko automatically configures GRUB based on the disk layout
  # Just ensure GRUB is enabled
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    forceInstall = true;
    fsIdentifier = "uuid";
  };

  # Ensure necessary modules are available in initrd
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  # Enable support for xfs in initrd
  boot.initrd.supportedFilesystems = ["xfs"];
}
