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
    ../../modules/osquery.nix
    ../../modules/podman.nix
    ../../modules/caddy-http3.nix
    ./harbor
  ];

  networking.hostName = "homelab-harbor";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.174";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-harbor.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        # Docker registry API
        handle /v2/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Harbor API - direct to core
        handle /api/* {
          reverse_proxy 127.0.0.1:8080
        }

        # OIDC callbacks - direct to core
        handle /c/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Service endpoints - direct to core
        handle /service/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Harbor portal (static UI)
        handle {
          reverse_proxy 127.0.0.1:8081
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."harbor.homelab.local harbor.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        # Docker registry API
        handle /v2/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Harbor API - direct to core
        handle /api/* {
          reverse_proxy 127.0.0.1:8080
        }

        # OIDC callbacks - direct to core
        handle /c/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Service endpoints - direct to core
        handle /service/* {
          reverse_proxy 127.0.0.1:8080
        }

        # Harbor portal (static UI)
        handle {
          reverse_proxy 127.0.0.1:8081
        }
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
    # podman1 = the harbor-net bridge. Without trusting it, the host firewall
    # drops container -> 10.89.0.1:53 traffic to aardvark-dns, so harbor-core
    # can't resolve harbor-redis/db and hangs at "initializing cache", which in
    # turn wedges harbor-bootstrap and stalls every colmena activation.
    trustedInterfaces = ["tailscale0" "podman1"];
    # Only Caddy is reachable. Harbor's own ports (core 8080, portal 8081) are
    # published on loopback for Caddy alone (hosts/harbor/harbor), and the
    # registry (5000) is not published at all: core reaches it over harbor-net
    # by name, and clients go through Caddy -> core, which is where auth lives.
    # They used to be open here, which exposed the token-less registry and the
    # core API over plain HTTP to the whole LAN.
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP (Caddy redirect)
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
  };
}
