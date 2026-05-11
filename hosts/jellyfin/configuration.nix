{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
  ];

  networking.hostName = "homelab-jellyfin";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.180";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # ZFS support
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "a8c0e180"; # Required for ZFS - unique 8-char hex

  # ZFS media pool mount
  # Dataset created on Proxmox host with:
  #   zfs create -o recordsize=1M -o compression=lz4 -o atime=off \
  #     -o xattr=sa -o acltype=posixacl -o primarycache=metadata \
  #     zfs_pool/media
  # Then passed to VM as virtio disk or NFS mount
  fileSystems."/media" = {
    device = "mediapool/media";
    fsType = "zfs";
    options = [
      "zfsutil"
      "X-mount.mkdir"
    ];
  };

  # ZFS kernel tuning for media streaming workloads
  boot.kernelParams = [
    "zfs.zfs_arc_max=2147483648" # 2GB max ARC (adjust based on RAM)
    "zfs.zfs_prefetch_disable=0" # Enable prefetch for sequential reads
  ];

  # ZFS services
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    trim.enable = true;
  };

  # Jellyfin media server
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # Ensure media directory permissions
  systemd.tmpfiles.rules = [
    "d /media 0755 jellyfin jellyfin -"
    "d /media/movies 0755 jellyfin jellyfin -"
    "d /media/hofvarpnir 0755 jellyfin jellyfin -"
    "d /media/tv 0755 jellyfin jellyfin -"
    "d /media/music 0755 jellyfin jellyfin -"
  ];

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-jellyfin.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        reverse_proxy localhost:8096
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."jellyfin.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8096
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      8096 # Jellyfin HTTP
      9100 # Node exporter
    ];
  };

  # Media and ZFS tools
  environment.systemPackages = with pkgs; [
    ffmpeg
    mediainfo
    zfs
  ];
}
