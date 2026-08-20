{
  config,
  lib,
  pkgs,
  ...
}: let
  # Attic namespaces every binary-cache URL under the cache name:
  # /{cache}/nix-cache-info, /{cache}/{hash}.narinfo, /{cache}/nar/{...}.
  # So the only safe layout is "Garage claims /s3/*, atticd gets the rest" —
  # an explicit allowlist of attic paths cannot work, because the cache name is
  # the first segment and is not known here.
  #
  # This previously ended in `handle { respond "OK" 200 }`, which answered
  # /{cache}/nix-cache-info itself: nix got the literal body "OK" where it
  # expected cache metadata, and the cache silently never functioned.
  cacheRouting = ''
    # Garage S3 API
    handle /s3/* {
      uri strip_prefix /s3
      reverse_proxy localhost:3900
    }

    # Health probe. Attic has no unauthenticated root route, so uptime checks
    # need a path of their own rather than relying on a catch-all responder.
    handle /health {
      respond "OK" 200
    }

    # Everything else is atticd: /api/* plus every per-cache binary-cache path.
    handle {
      reverse_proxy localhost:8080
    }
  '';
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
    ./garage
    ./attic
    ../../modules/caddy-http3.nix
  ];

  networking.hostName = "homelab-cache";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.175";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-cache.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        ${cacheRouting}
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."cache.homelab.local cache.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        ${cacheRouting}
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP
      443 # HTTPS (Caddy)
      3900 # Garage S3 API
      3901 # Garage RPC
      3902 # Garage Admin API
      8080 # Attic
      9100 # Node exporter
    ];
  };
}
