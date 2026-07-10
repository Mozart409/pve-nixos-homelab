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
        ];
        local-data = [
          # keep-sorted start
          ''"albyhub.homelab.local. A 192.168.2.149"''
          ''"axon.homelab.local. A 192.168.2.149"''
          ''"buildbot-master.homelab.local. A 192.168.2.177"''
          ''"buildbot-worker-1.homelab.local. A 192.168.2.179"''
          # Homelab services with step-ca certificates
          ''"ca.homelab.local. A 192.168.2.160"''
          ''"cache.homelab.local. A 192.168.2.175"''
          ''"containers.homelab.local. A 192.168.2.149"''
          ''"dashboard.homelab.local. A 192.168.2.149"''
          ''"database.homelab.local. A 192.168.2.134"''
          ''"dns.homelab.local. A 192.168.2.145"''
          ''"fleet.homelab.local. A 192.168.2.164"''
          ''"forgejo.homelab.local. A 192.168.2.178"''
          ''"harbor.homelab.local. A 192.168.2.174"''
          ''"hermes.homelab.local. A 192.168.2.155"''
          ''"homeassistant.local. A 192.168.2.208"''
          ''"jellyfin.homelab.local. A 192.168.2.180"''
          ''"k3s-agent-1.homelab.local. A 192.168.2.156"''
          ''"k3s-server-1.homelab.local. A 192.168.2.165"''
          ''"loki-mcp.homelab.local. A 192.168.2.152"''
          ''"loki.homelab.local. A 192.168.2.135"''
          ''"mcp.homelab.local. A 192.168.2.152"''
          ''"otel.homelab.local. A 192.168.2.135"''
          ''"pbs-mcp.homelab.local. A 192.168.2.152"''
          ''"pg-mcp.homelab.local. A 192.168.2.152"''
          ''"pgadmin.homelab.local. A 192.168.2.134"''
          ''"prom-mcp.homelab.local. A 192.168.2.152"''
          ''"prometheus.homelab.local. A 192.168.2.135"''
          ''"pve-gigabyte.local. A 192.168.2.42"''
          ''"romm.homelab.local. A 192.168.2.149"''
          ''"searxng.homelab.local. A 192.168.2.149"''
          ''"tempo.homelab.local. A 192.168.2.135"''
          ''"unifi.homelab.local. A 192.168.2.142"''
          ''"wotan.homelab.local. A 192.168.2.71"''
          # keep-sorted end
        ];
        local-data-ptr = [
          # keep-sorted start
          ''"192.168.2.134 database.homelab.local"''
          ''"192.168.2.134 pgadmin.homelab.local"''
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
          ''"192.168.2.149 romm.homelab.local"''
          ''"192.168.2.149 searxng.homelab.local"''
          ''"192.168.2.152 loki-mcp.homelab.local"''
          ''"192.168.2.152 mcp.homelab.local"''
          ''"192.168.2.152 pbs-mcp.homelab.local"''
          ''"192.168.2.152 pg-mcp.homelab.local"''
          ''"192.168.2.152 prom-mcp.homelab.local"''
          ''"192.168.2.155 hermes.homelab.local"''
          ''"192.168.2.156 k3s-agent-1.homelab.local"''
          ''"192.168.2.160 ca.homelab.local"''
          ''"192.168.2.164 fleet.homelab.local"''
          ''"192.168.2.165 k3s-server-1.homelab.local"''
          ''"192.168.2.174 harbor.homelab.local"''
          ''"192.168.2.175 cache.homelab.local"''
          ''"192.168.2.177 buildbot-master.homelab.local"''
          ''"192.168.2.178 forgejo.homelab.local"''
          ''"192.168.2.179 buildbot-worker-1.homelab.local"''
          ''"192.168.2.180 jellyfin.homelab.local"''
          ''"192.168.2.208 homeassistant.local"''
          ''"192.168.2.42 pve-gigabyte.local"''
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

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
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
    virtualHosts."dns.homelab.local" = {
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
