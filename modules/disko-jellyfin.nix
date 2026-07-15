{lib, ...}: {
  disko.devices = {
    disk = {
      # OS disk (scsi0 -> /dev/sda): btrfs, mirrors modules/disko-config.nix
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            # BIOS boot partition for GRUB
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
            root = {
              size = "100%";
              label = "nixos";
              content = {
                type = "btrfs";
                extraArgs = ["-f" "-L" "nixos"];
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/home" = {
                    mountpoint = "/home";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/var" = {
                    mountpoint = "/var";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/swap" = {
                    mountpoint = "/.swapvol";
                    swap.swapfile.size = "4G";
                  };
                };
              };
            };
          };
        };
      };

      # Media disk (scsi1 -> /dev/sdb): whole disk handed to the ZFS media pool.
      # This is the raw virtio disk the (commented) Jellyfin VM in iac/main.tf
      # attaches as scsi1.
      media = {
        type = "disk";
        device = lib.mkDefault "/dev/sdb";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "mediapool";
              };
            };
          };
        };
      };
    };

    # ZFS pool tuned for large, mostly-sequential media reads.
    zpool = {
      mediapool = {
        type = "zpool";
        # Single-vdev stripe: redundancy lives on the Proxmox ZFS host, not
        # inside the VM.
        mode = "";

        options = {
          # 4K sectors: safe minimum for modern disks / virtio-backed zvols.
          ashift = "12";
          autotrim = "on";
        };

        # Inherited defaults for every dataset in the pool.
        rootFsOptions = {
          # "Bigger pages": 1M records suit large video files -> fewer IOPS,
          # better compression ratio, less metadata overhead.
          recordsize = "1M";
          # Media is already compressed; lz4's early-abort makes it ~free while
          # still shrinking incompressible-detection metadata + text sidecars.
          compression = "lz4";
          atime = "off";
          # Store xattrs in the dnode (faster) and let dnodes size to fit.
          xattr = "sa";
          dnodesize = "auto";
          acltype = "posixacl";
          "com.sun:auto-snapshot" = "false";
          # Pool root is a container only; real data lives in child datasets.
          mountpoint = "none";
        };

        datasets = {
          media = {
            type = "zfs_fs";
            mountpoint = "/media";
            options = {
              recordsize = "1M";
              # Streaming reads are one-shot: cache metadata, not the multi-GB
              # data blocks, so the ARC stays useful for directory walks.
              primarycache = "metadata";
              # Optimise the (rare) large writes for throughput over latency.
              logbias = "throughput";
              # One extra metadata copy is plenty for bulk media.
              redundant_metadata = "most";
            };
          };
        };
      };
    };
  };

  # GRUB bootloader configuration (same as the shared disko-config.nix).
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    forceInstall = true;
    fsIdentifier = "uuid";
  };

  # Ensure necessary modules are available in initrd.
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  # btrfs for root, zfs for the media pool.
  boot.initrd.supportedFilesystems = ["btrfs" "zfs"];
}
