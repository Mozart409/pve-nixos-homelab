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
              endpoint: "0.0.0.0:4317"
            http:
              endpoint: "0.0.0.0:4318"

      processors:
        batch:
          timeout: 5s
          send_batch_size: 1000

      exporters:
        debug:
          verbosity: basic

        otlphttp/tempo:
          endpoint: "http://127.0.0.1:4328"
          tls:
            insecure: true

        loki:
          endpoint: "http://127.0.0.1:3100/loki/api/v1/push"

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo, debug]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [loki, debug]
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

  # Loki for log aggregation
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9096;
      };
      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      limits_config = {
        retention_period = "720h"; # 30 days
        allow_structured_metadata = true;
        volume_enabled = true;
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
      };
    };
  };

  # Tempo for distributed tracing
  services.tempo = {
    enable = true;
    settings = {
      server = {
        http_listen_port = 3200;
        grpc_listen_port = 9097;
      };
      distributor.receivers = {
        otlp.protocols = {
          grpc.endpoint = "127.0.0.1:4327";
          http.endpoint = "127.0.0.1:4328";
        };
      };
      storage.trace = {
        backend = "local";
        local.path = "/var/lib/tempo/traces";
        wal.path = "/var/lib/tempo/wal";
        block = {
          bloom_filter_false_positive = 0.05;
          v2_index_downsample_bytes = 1000;
          v2_encoding = "zstd";
        };
      };
      compactor = {
        compaction = {
          block_retention = "720h"; # 30 days
        };
      };
      metrics_generator = {
        registry.external_labels = {
          source = "tempo";
          environment = "homelab";
        };
        storage = {
          path = "/var/lib/tempo/generator/wal";
          remote_write = [
            {
              url = "http://localhost:9090/api/v1/write";
              send_exemplars = true;
            }
          ];
        };
      };
      overrides.defaults.metrics_generator.processors = ["service-graphs" "span-metrics"];
    };
  };

  services.prometheus = {
    enable = true;
    port = 9090;
    retentionTime = "30d";
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
            targets = ["192.168.2.145:9100"];
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
      # Containers host exporters
      {
        job_name = "containers-node";
        static_configs = [
          {
            targets = ["192.168.2.149:9100"];
            labels = {
              instance = "homelab-containers";
            };
          }
        ];
      }
      {
        job_name = "containers-postgres";
        static_configs = [
          {
            targets = ["192.168.2.149:9187"];
            labels = {
              instance = "homelab-containers";
              db = "uptime-forge";
            };
          }
        ];
      }
      # MCP host exporters
      {
        job_name = "mcp-node";
        static_configs = [
          {
            targets = ["192.168.2.152:9100"];
            labels = {
              instance = "homelab-mcp";
            };
          }
        ];
      }
      # Hermes host exporters
      {
        job_name = "hermes-node";
        static_configs = [
          {
            targets = ["192.168.2.155:9100"];
            labels = {
              instance = "homelab-hermes";
            };
          }
        ];
      }
      # K3s server exporters
      {
        job_name = "k3s-server-1-node";
        static_configs = [
          {
            targets = ["192.168.2.157:9100"];
            labels = {
              instance = "k3s-server-1";
            };
          }
        ];
      }
      # K3s agent exporters
      {
        job_name = "k3s-agent-1-node";
        static_configs = [
          {
            targets = ["192.168.2.156:9100"];
            labels = {
              instance = "k3s-agent-1";
            };
          }
        ];
      }
    ];
  };

  age.secrets.grafana-secret-key = {
    file = ../../secrets/grafana-secret-key.age;
    owner = "grafana";
    group = "grafana";
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
        secret_key = "$__file{${config.age.secrets.grafana-secret-key.path}}";
      };
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          url = "http://localhost:9090";
          isDefault = true;
          jsonData = {
            timeInterval = config.services.prometheus.globalConfig.scrape_interval;
          };
        }
        {
          name = "Loki";
          type = "loki";
          uid = "loki";
          url = "http://localhost:3100";
          jsonData = {
            maxLines = 1000;
            derivedFields = [
              {
                name = "TraceID";
                matcherRegex = "traceID=(\\w+)";
                url = "$${__value.raw}";
                datasourceUid = "tempo";
              }
            ];
          };
        }
        {
          name = "Tempo";
          type = "tempo";
          uid = "tempo";
          url = "http://localhost:3200";
          jsonData = {
            tracesToLogsV2 = {
              datasourceUid = "loki";
              spanStartTimeShift = "-1h";
              spanEndTimeShift = "1h";
              filterByTraceID = true;
              filterBySpanID = true;
            };
            tracesToMetrics = {
              datasourceUid = "prometheus";
            };
            serviceMap = {
              datasourceUid = "prometheus";
            };
            nodeGraph = {
              enabled = true;
            };
            lokiSearch = {
              datasourceUid = "loki";
            };
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

        handle_path /loki* {
          reverse_proxy localhost:3100
        }

        handle_path /tempo* {
          reverse_proxy localhost:3200
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
      3100 # Loki HTTP
      3200 # Tempo HTTP
      8888 # Collector metrics
    ];
  };

  environment.systemPackages = with pkgs; [
    opentelemetry-collector-contrib
  ];
}
