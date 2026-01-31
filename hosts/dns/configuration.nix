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
  ];

  networking.hostName = "homelab-dns";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.137";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["127.0.0.1" "1.1.1.1"];

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

        # DNSSEC validation
        auto-trust-anchor-file = "${pkgs.dns-root-data}/root.key";

        # Logging
        verbosity = 1;
        log-queries = false;
        log-replies = false;
        log-servfail = true;

        # Static local DNS records
        local-zone = [
          "local. static"
        ];
        local-data = [
          ''"homeassistant.local. A 192.168.2.208"''
          ''"pve-gigabyte.local. A 192.168.2.42"''
        ];
        local-data-ptr = [
          ''"192.168.2.208 homeassistant.local"''
          ''"192.168.2.42 pve-gigabyte.local"''
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
      RestartSec = 5;
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
