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
    ../../modules/fluent-bit.nix
    ../../modules/podman.nix
    ../../modules/caddy-http3.nix
    ./albyhub
    ./open-webui
    ./searxng
    # axon-gateway moved to hosts/mcp_vm/axon-gateway on 2026-09-14 so the
    # MCP servers it fronts could go loopback-only.
    ./homelab-dashboard
    ./romm
    # Harbor moved to dedicated VM (hosts/harbor)
  ];

  networking.hostName = "homelab-containers";

  # Disable IPv6 - LXC container doesn't have proper IPv6 routing
  # which breaks Tailscale connections preferring IPv6
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.149";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # The node exporter is enabled fleet-wide by modules/common.nix. (The
  # postgres exporter for the uptime-forge TimescaleDB left with it on
  # 2026-09-12 -- see the retirement note under services.caddy.)

  # Open WebUI now lives in ./open-webui (listens on localhost:8088)

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-containers.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        # Open WebUI is a SvelteKit SPA with a build-time base path of "/",
        # so it must be served at the host root (not a subpath).
        handle {
          reverse_proxy localhost:8088
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."containers.homelab.local containers.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        # Open WebUI is a SvelteKit SPA with a build-time base path of "/",
        # so it must be served at the host root (not a subpath).
        handle {
          reverse_proxy localhost:8088
        }
      '';
    };

    # (Both vhosts above carried a `handle /uptime-forge*` -> localhost:3000
    # until 2026-09-12, when uptime-forge and its TimescaleDB were retired as
    # unused. hosts/containers/uptime-forge/ is kept on disk, imported nowhere
    # -- same convention as ./futo-notes and hosts/cache/. The podman volume
    # `uptime_forge_db` and /var/lib/uptime-forge stay on the host untouched.)

    # AlbyHub on its own hostname (SPA expects to be served at root)
    virtualHosts."albyhub.homelab.local albyhub.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy 127.0.0.1:8080
      '';
    };

    # SearXNG on its own hostname so off-host clients (e.g. hermes-agent's
    # web_search backend) can reach it. SearXNG binds 127.0.0.1:8089, so Caddy
    # — running on this host — is the only thing that proxies to it.
    virtualHosts."searxng.homelab.local searxng.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8089
      '';
    };

    # homelab-dashboard. Binds 127.0.0.1:8084 (see ./homelab-dashboard), so
    # Caddy is the only thing that proxies to it. Served at its own hostname.
    virtualHosts."dashboard.homelab.local dashboard.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8084
      '';
    };

    # RomM (ROM manager). Binds 127.0.0.1:8095 (see ./romm), so Caddy is the only
    # thing that proxies to it. RomM is a root-served SPA (no URL subpath
    # support), so it gets its own hostname. The Pocket ID OIDC callback is
    # https://romm.homelab.local/api/oauth/openid.
    virtualHosts."romm.homelab.local romm.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8095
      '';
    };

    # (The FUTO Notes vhost lived here until 2026-09-09, when the service was
    # retired as unused. hosts/containers/futo-notes/ is kept on disk, imported
    # nowhere -- same convention as hosts/cache/.)
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
      9100 # Node exporter
    ];
  };
}
