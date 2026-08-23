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
    ../../modules/caddy-http3.nix
  ];

  networking.hostName = "homelab-dns";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.145";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["127.0.0.1" "192.168.2.1"]; # Override: DNS server uses localhost

  # Unbound DNS resolver with systemd integration
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Listen on all interfaces for local network DNS
        interface = ["0.0.0.0" "::0"];
        port = 53;

        # Access control - allow local network
        access-control = [
          "127.0.0.0/8 allow"
          "192.168.2.0/24 allow"
          "::1/128 allow"
          # Tailnet clients query this node's own LAN IP (192.168.2.145) via the
          # subnet router. Traffic terminating on the router itself is NOT
          # SNATed, so unbound sees the client's raw Tailscale CGNAT source
          # address rather than a 192.168.2.x one. Allow the tailnet ranges so
          # split-DNS lookups from remote clients aren't silently dropped.
          "100.64.0.0/10 allow"
          "fd7a:115c:a1e0::/48 allow"
        ];

        # Performance and caching settings
        num-threads = 2;
        msg-cache-slabs = 4;
        rrset-cache-slabs = 4;
        infra-cache-slabs = 4;
        key-cache-slabs = 4;
        rrset-cache-size = "100m";
        msg-cache-size = "50m";

        # Prefetch popular entries before they expire
        prefetch = true;
        prefetch-key = true;

        # Security hardening
        harden-glue = true;
        harden-dnssec-stripped = true;
        harden-referral-path = true;
        use-caps-for-id = false;

        # Privacy settings
        hide-identity = true;
        hide-version = true;
        qname-minimisation = true;

        # Buffer size for EDNS
        edns-buffer-size = 1232;

        # Root hints for recursive resolution
        root-hints = "${pkgs.dns-root-data}/root.hints";

        # DNSSEC validation is handled automatically by NixOS via enableRootTrustAnchor (default true)
        # which uses a writable state directory for auto-trust-anchor-file

        # Logging
        verbosity = 1;
        log-queries = false;
        log-replies = false;
        log-servfail = true;

        # Static local DNS records
        local-zone = [
          "local. static"
          "homelab.local. static"
          # Parallel private zone. Apple clients force *.local to mDNS/Bonjour and
          # never send it to a unicast resolver, so homelab.local is unreachable
          # from macOS/iOS over Tailscale split DNS. homelab.internal (ICANN-
          # reserved private TLD) resolves normally. Both zones are served.
          "homelab.internal. static"
        ];
        local-data = [
          # keep-sorted start
          # homelab.internal mirror of every homelab.local A record (parallel
          # zone for Apple clients — see the local-zone note). keep-sorted
          # interleaves these with the .local entries on commit.
          ''"albyhub.homelab.internal. A 192.168.2.149"''
          ''"albyhub.homelab.local. A 192.168.2.149"''
          ''"alertmanager.homelab.internal. A 192.168.2.135"''
          ''"alertmanager.homelab.local. A 192.168.2.135"''
          ''"axon.homelab.internal. A 192.168.2.149"''
          ''"axon.homelab.local. A 192.168.2.149"''
          ''"ca.homelab.internal. A 192.168.2.160"''
          # Homelab services with step-ca certificates
          ''"ca.homelab.local. A 192.168.2.160"''
          ''"cache.homelab.internal. A 192.168.2.175"''
          ''"cache.homelab.local. A 192.168.2.175"''
          ''"ci.homelab.internal. A 192.168.2.182"''
          # WOODPECKER_HOST -- the name baked into OAuth redirects and webhooks.
          ''"ci.homelab.local. A 192.168.2.182"''
          ''"containers.homelab.internal. A 192.168.2.149"''
          ''"containers.homelab.local. A 192.168.2.149"''
          ''"dashboard.homelab.internal. A 192.168.2.149"''
          ''"dashboard.homelab.local. A 192.168.2.149"''
          ''"database.homelab.internal. A 192.168.2.134"''
          ''"database.homelab.local. A 192.168.2.134"''
          ''"development.homelab.internal. A 192.168.2.184"''
          ''"development.homelab.local. A 192.168.2.184"''
          ''"dns.homelab.internal. A 192.168.2.145"''
          ''"dns.homelab.local. A 192.168.2.145"''
          ''"fleet.homelab.internal. A 192.168.2.164"''
          ''"fleet.homelab.local. A 192.168.2.164"''
          ''"forgejo.homelab.internal. A 192.168.2.178"''
          ''"forgejo.homelab.local. A 192.168.2.178"''
          ''"harbor.homelab.internal. A 192.168.2.174"''
          ''"harbor.homelab.local. A 192.168.2.174"''
          ''"hermes.homelab.internal. A 192.168.2.155"''
          ''"hermes.homelab.local. A 192.168.2.155"''
          ''"hofvarpnir.homelab.internal. A 192.168.2.180"''
          ''"hofvarpnir.homelab.local. A 192.168.2.180"''
          ''"homeassistant.local. A 192.168.2.208"''
          ''"jellyfin.homelab.internal. A 192.168.2.180"''
          ''"jellyfin.homelab.local. A 192.168.2.180"''
          ''"loki-mcp.homelab.internal. A 192.168.2.152"''
          ''"loki-mcp.homelab.local. A 192.168.2.152"''
          ''"loki.homelab.internal. A 192.168.2.135"''
          ''"loki.homelab.local. A 192.168.2.135"''
          ''"mcp.homelab.internal. A 192.168.2.152"''
          ''"mcp.homelab.local. A 192.168.2.152"''
          ''"notes.homelab.internal. A 192.168.2.149"''
          ''"notes.homelab.local. A 192.168.2.149"''
          ''"otel.homelab.internal. A 192.168.2.135"''
          ''"otel.homelab.local. A 192.168.2.135"''
          ''"pbs-mcp.homelab.internal. A 192.168.2.152"''
          ''"pbs-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-appdb-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-appdb-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-forgejo-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-forgejo-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-hofvarpnir-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-hofvarpnir-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-romm-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-romm-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-terraform-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-terraform-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-uptime-mcp.homelab.internal. A 192.168.2.152"''
          ''"pg-uptime-mcp.homelab.local. A 192.168.2.152"''
          ''"pgadmin.homelab.internal. A 192.168.2.134"''
          ''"pgadmin.homelab.local. A 192.168.2.134"''
          ''"prom-mcp.homelab.internal. A 192.168.2.152"''
          ''"prom-mcp.homelab.local. A 192.168.2.152"''
          ''"prometheus.homelab.internal. A 192.168.2.135"''
          ''"prometheus.homelab.local. A 192.168.2.135"''
          ''"pve-gigabyte.homelab.internal. A 192.168.2.46"''
          ''"pve-gigabyte.homelab.local. A 192.168.2.46"''
          ''"pve-gigabyte.local. A 192.168.2.46"''
          ''"romm.homelab.internal. A 192.168.2.149"''
          ''"romm.homelab.local. A 192.168.2.149"''
          ''"scratchpad.homelab.internal. A 192.168.2.185"''
          ''"scratchpad.homelab.local. A 192.168.2.185"''
          ''"searxng.homelab.internal. A 192.168.2.149"''
          ''"searxng.homelab.local. A 192.168.2.149"''
          ''"tempo.homelab.internal. A 192.168.2.135"''
          ''"tempo.homelab.local. A 192.168.2.135"''
          ''"unifi.homelab.internal. A 192.168.2.142"''
          ''"unifi.homelab.local. A 192.168.2.142"''
          ''"woodpecker.homelab.internal. A 192.168.2.182"''
          ''"woodpecker.homelab.local. A 192.168.2.182"''
          ''"wotan.homelab.internal. A 192.168.2.71"''
          ''"wotan.homelab.local. A 192.168.2.71"''
          ''"wp-mcp.homelab.internal. A 192.168.2.152"''
          ''"wp-mcp.homelab.local. A 192.168.2.152"''
          ''"zeroclaw.homelab.internal. A 192.168.2.183"''
          ''"zeroclaw.homelab.local. A 192.168.2.183"''
          # keep-sorted end
        ];
        local-data-ptr = [
          # keep-sorted start
          ''"192.168.2.134 database.homelab.local"''
          ''"192.168.2.134 pgadmin.homelab.local"''
          ''"192.168.2.135 alertmanager.homelab.local"''
          ''"192.168.2.135 loki.homelab.local"''
          ''"192.168.2.135 otel.homelab.local"''
          ''"192.168.2.135 prometheus.homelab.local"''
          ''"192.168.2.135 tempo.homelab.local"''
          ''"192.168.2.142 unifi.homelab.local"''
          ''"192.168.2.145 dns.homelab.local"''
          ''"192.168.2.149 albyhub.homelab.local"''
          ''"192.168.2.149 axon.homelab.local"''
          ''"192.168.2.149 containers.homelab.local"''
          ''"192.168.2.149 dashboard.homelab.local"''
          ''"192.168.2.149 notes.homelab.local"''
          ''"192.168.2.149 romm.homelab.local"''
          ''"192.168.2.149 searxng.homelab.local"''
          ''"192.168.2.152 loki-mcp.homelab.local"''
          ''"192.168.2.152 mcp.homelab.local"''
          ''"192.168.2.152 pbs-mcp.homelab.local"''
          ''"192.168.2.152 pg-appdb-mcp.homelab.local"''
          ''"192.168.2.152 pg-forgejo-mcp.homelab.local"''
          ''"192.168.2.152 pg-hofvarpnir-mcp.homelab.local"''
          ''"192.168.2.152 pg-romm-mcp.homelab.local"''
          ''"192.168.2.152 pg-terraform-mcp.homelab.local"''
          ''"192.168.2.152 pg-uptime-mcp.homelab.local"''
          ''"192.168.2.152 prom-mcp.homelab.local"''
          ''"192.168.2.152 wp-mcp.homelab.local"''
          ''"192.168.2.155 hermes.homelab.local"''
          ''"192.168.2.160 ca.homelab.local"''
          ''"192.168.2.164 fleet.homelab.local"''
          ''"192.168.2.174 harbor.homelab.local"''
          ''"192.168.2.175 cache.homelab.local"''
          ''"192.168.2.178 forgejo.homelab.local"''
          ''"192.168.2.180 hofvarpnir.homelab.local"''
          ''"192.168.2.180 jellyfin.homelab.local"''
          ''"192.168.2.182 ci.homelab.local"''
          ''"192.168.2.182 woodpecker.homelab.local"''
          ''"192.168.2.183 zeroclaw.homelab.local"''
          ''"192.168.2.184 development.homelab.local"''
          ''"192.168.2.185 scratchpad.homelab.local"''
          ''"192.168.2.208 homeassistant.local"''
          ''"192.168.2.46 pve-gigabyte.homelab.local"''
          ''"192.168.2.46 pve-gigabyte.local"''
          ''"192.168.2.71 wotan.homelab.local"''
          # keep-sorted end
        ];
      };

      # Forward zone for upstream DNS (using DNS over TLS)
      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "1.1.1.1@853#cloudflare-dns.com"
            "1.0.0.1@853#cloudflare-dns.com"
            "9.9.9.9@853#dns.quad9.net"
            "149.112.112.112@853#dns.quad9.net"
          ];
          forward-tls-upstream = true;
        }
      ];
    };
  };

  # Ensure unbound starts after network is ready
  systemd.services.unbound = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Restart = "on-failure";
    };
  };

  # Caddy reverse proxy with Tailscale TLS for management interface
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-dns.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          respond "DNS Server OK" 200
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."dns.homelab.local dns.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          respond "DNS Server OK" 200
        }
      '';
    };
  };

  # Subnet router: advertise the LAN so tailnet clients (e.g. a laptop while
  # away) can reach *.homelab.local by their real 192.168.2.x addresses and hit
  # the internal Caddy vhosts with genuine step-ca certs. "server" enables
  # net.ipv4.ip_forward. Pair with a split-DNS entry (homelab.local ->
  # 192.168.2.145) in the Tailscale admin console.
  # NOTE: tailscaled-autoconnect only runs `tailscale up` when not already
  # connected, so on an already-authed node apply the route once by hand:
  #   sudo tailscale set --advertise-routes=192.168.2.0/24
  services.tailscale.useRoutingFeatures = "server";
  services.tailscale.extraUpFlags = ["--advertise-routes=192.168.2.0/24"];

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      53 # DNS
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
    allowedUDPPorts = [
      53 # DNS
    ];
  };

  environment.systemPackages = with pkgs; [
    bind # For dig/nslookup utilities
    ldns # For drill DNS tool
  ];
}
