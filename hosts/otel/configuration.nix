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

  networking.hostName = "homelab-otel";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.135";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  # OpenTelemetry Collector (contrib build)
  users.users.otelcol = {
    isSystemUser = true;
    group = "otelcol";
    description = "OpenTelemetry Collector user";
  };
  users.groups.otelcol = {};

  environment.etc."otelcol/config.yaml" = {
    user = "otelcol";
    group = "otelcol";
    mode = "0644";
    text = ''
      receivers:
        otlp:
          protocols:
            grpc:
            http:

      processors:
        batch: {}

      exporters:
        debug:
          verbosity: basic

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
    '';
  };

  systemd.services.otel-collector = {
    description = "OpenTelemetry Collector";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = ''${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config /etc/otelcol/config.yaml'';
      User = "otelcol";
      Group = "otelcol";
      Restart = "on-failure";
      RestartSec = 5;
      CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
      AmbientCapabilities = "CAP_NET_BIND_SERVICE";
    };
  };

  services.prometheus = {
    enable = true;
    port = 9090;
    retentionTime = "15d";
    webExternalUrl = "https://homelab-otel.dropbear-butterfly.ts.net/prometheus";
    extraFlags = ["--web.route-prefix=/"];

    globalConfig = {
      scrape_interval = "30s";
      scrape_timeout = "10s";
      evaluation_interval = "30s";
      external_labels = {
        environment = "homelab";
        datacenter = "home";
      };
    };

    exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
    };

    scrapeConfigs = [
      {
        job_name = "prometheus";
        static_configs = [
          {
            targets = ["localhost:9090"];
          }
        ];
      }
      {
        job_name = "otel-node";
        static_configs = [
          {
            targets = ["localhost:${toString config.services.prometheus.exporters.node.port}"];
          }
        ];
      }
      {
        job_name = "otel-collector";
        static_configs = [
          {
            targets = ["localhost:8888"];
          }
        ];
      }
      # Database host exporters
      {
        job_name = "database-node";
        static_configs = [
          {
            targets = ["192.168.2.134:9100"];
            labels = {
              instance = "homelab-database";
            };
          }
        ];
      }
      {
        job_name = "database-postgres";
        static_configs = [
          {
            targets = ["192.168.2.134:9187"];
            labels = {
              instance = "homelab-database";
            };
          }
        ];
      }
      # DNS host exporters
      {
        job_name = "dns-node";
        static_configs = [
          {
            targets = ["192.168.2.136:9100"];
            labels = {
              instance = "homelab-dns";
            };
          }
        ];
      }
      # UniFi host exporters
      {
        job_name = "unifi-node";
        static_configs = [
          {
            targets = ["192.168.2.142:9100"];
            labels = {
              instance = "homelab-unifi";
            };
          }
        ];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        root_url = "https://homelab-otel.dropbear-butterfly.ts.net/grafana/";
        serve_from_sub_path = true;
      };
      security = {
        admin_user = "admin";
        admin_password = "admin";
      };
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://localhost:9090";
          isDefault = true;
          jsonData = {
            timeInterval = config.services.prometheus.globalConfig.scrape_interval;
          };
        }
      ];
    };
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;
    virtualHosts."homelab-otel.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle_path /prometheus* {
          reverse_proxy localhost:9090
        }

        handle /grafana* {
          reverse_proxy localhost:3000
        }

        handle {
          respond "OK" 200
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
      443 # HTTPS (Caddy)
      4317 # OTLP gRPC
      4318 # OTLP HTTP
      8888 # Collector metrics
    ];
  };

  environment.systemPackages = with pkgs; [
    opentelemetry-collector-contrib
  ];
}
