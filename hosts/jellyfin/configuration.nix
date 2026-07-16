{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    # Dedicated disko layout: btrfs OS disk + optimized ZFS media pool.
    ../../modules/disko-jellyfin.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    # Podman + oci-containers backend for the hofvarpnir container below.
    ../../modules/podman.nix
    # Declaratively pinned SSO/OIDC plugin (Pocket ID auth).
    ./sso-plugin.nix
    # hofvarpnir media fetch-and-store app (OCI container, migrated off the LXC).
    ./hofvarpnir.nix
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

  # The mediapool ZFS pool and its /media dataset are created and mounted
  # declaratively by modules/disko-jellyfin.nix (recordsize=1M, lz4, atime=off,
  # xattr=sa, primarycache=metadata). No manual fileSystems entry needed.

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

  # NFS export of the hofvarpnir media dir.
  #
  # hofvarpnir (fetch-and-store media app on an old Rocky LXC, 192.168.2.100, same
  # Proxmox host / segment) mounts this and writes completed downloads straight onto
  # the tuned ZFS pool — no copy, no sync, no delete-war. It owns the file lifecycle
  # (15-min retention cleanup); Jellyfin just reads. Jellyfin metadata stays in
  # /var/lib/jellyfin ("save artwork/NFO into media folders" OFF) so cleanup never
  # collides with it.
  #
  # NFSv4-only so the firewall needs a single port (2049). all_squash + anonuid/anongid
  # map every client write to jellyfin:jellyfin (uid/gid 999) regardless of the
  # Rocky-side UID, matching the existing /media ownership (no re-chown needed).
  # fsid=0 makes this the NFSv4 pseudo-root: hofvarpnir mounts `192.168.2.180:/`.
  services.nfs.server = {
    enable = true;
    exports = ''
      /media/hofvarpnir 192.168.2.100(rw,sync,no_subtree_check,fsid=0,all_squash,anonuid=999,anongid=999)
    '';
  };
  # Disable NFSv2/v3 so only TCP 2049 is needed (no rpcbind/mountd/statd ports).
  services.nfs.settings.nfsd = {
    vers2 = false;
    vers3 = false;
    vers4 = true;
  };

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

    # hofvarpnir (OCI container on 127.0.0.1:3000) served with a step-ca cert.
    # LAN-only: Tailscale can only cert/route this node's own name, so there is
    # no ts.net vhost — reach it over Tailscale via split-DNS to the dns host.
    # App serves /metrics + /dashboard at root, so no path stripping.
    #
    # TEMPORARILY DISABLED to serialize step-ca cert issuance: after the reinstall
    # both this and jellyfin.homelab.local needed brand-new certs at once, which
    # triggers a step-ca ACME badNonce storm (see caddy-stepca-badnonce memory).
    # Re-enable once jellyfin.homelab.local has obtained its cert solo.
    # virtualHosts."hofvarpnir.homelab.local" = {
    #   extraConfig = ''
    #     tls {
    #       ca https://ca.homelab.local:8443/acme/acme/directory
    #     }
    #
    #     reverse_proxy localhost:3000
    #   '';
    # };
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
      2049 # NFSv4 (hofvarpnir writes media onto the ZFS pool)
    ];
  };

  # Media and ZFS tools
  environment.systemPackages = with pkgs; [
    ffmpeg
    mediainfo
    zfs
  ];
}
