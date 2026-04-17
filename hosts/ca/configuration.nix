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

  networking.hostName = "homelab-ca";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.160";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.145" "1.1.1.1"];

  # step-ca Certificate Authority
  # Password for the intermediate CA key (created via agenix)
  age.secrets.step-ca-password = {
    file = ../../secrets/step-ca-password.age;
    owner = "step-ca";
    group = "step-ca";
    mode = "0400";
  };

  services.step-ca = {
    enable = true;
    openFirewall = true; # Opens port 443 by default
    address = "0.0.0.0";
    port = 8443;
    intermediatePasswordFile = config.age.secrets.step-ca-password.path;

    settings = {
      root = "/var/lib/step-ca/certs/root_ca.crt";
      crt = "/var/lib/step-ca/certs/intermediate_ca.crt";
      key = "/var/lib/step-ca/secrets/intermediate_ca_key";
      dnsNames = [
        "ca.homelab.local"
        "homelab-ca"
        "homelab-ca.dropbear-butterfly.ts.net"
        "192.168.2.160"
        "localhost"
      ];

      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
      };

      authority = {
        provisioners = [
          # ACME provisioner for automatic certificate issuance (like Let's Encrypt)
          {
            type = "ACME";
            name = "acme";
            # Allow HTTP-01 and TLS-ALPN-01 challenges
            challenges = ["http-01" "tls-alpn-01"];
          }
          # JWK provisioner for manual certificate requests via step CLI
          {
            type = "JWK";
            name = "admin";
            # This key will be generated during bootstrap
            key = {
              use = "sig";
              kty = "EC";
              crv = "P-256";
              alg = "ES256";
              # Placeholder - will be populated during bootstrap
              x = "";
              y = "";
            };
            encryptedKey = ""; # Placeholder - will be populated during bootstrap
          }
        ];

        claims = {
          # Certificate validity periods
          minTLSCertDuration = "5m";
          maxTLSCertDuration = "2160h"; # 90 days
          defaultTLSCertDuration = "720h"; # 30 days
        };
      };

      tls = {
        cipherSuites = [
          "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
          "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
        ];
        minVersion = 1.2;
        maxVersion = 1.3;
      };
    };
  };

  # Ensure step-ca starts after agenix decrypts secrets
  systemd.services.step-ca = {
    after = ["agenix.service"];
    wants = ["agenix.service"];
  };

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS for management interface
  services.caddy = {
    enable = true;
    virtualHosts."homelab-ca.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle /health {
          respond "CA Server OK" 200
        }

        # Proxy to step-ca for ACME directory
        handle {
          reverse_proxy localhost:8443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
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
      443 # HTTPS (Caddy/Tailscale)
      8443 # step-ca ACME endpoint (also opened by openFirewall)
      9100 # Node exporter
    ];
  };

  environment.systemPackages = with pkgs; [
    step-cli # step CLI for interacting with step-ca
  ];
}
