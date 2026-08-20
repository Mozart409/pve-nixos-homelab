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
    ./alerting.nix
    ./blackbox.nix
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
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
              cors:
                allowed_origins:
                  - "*"

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

        otlphttp/loki:
          endpoint: "http://127.0.0.1:3100/otlp"
          tls:
            insecure: true

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
            exporters: [otlphttp/loki, debug]
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
        retention_period = "168h"; # 7 days
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
        };
      };
      # Tempo 3.0 removed the `compactor` component and the v2 block
      # encoding entirely; compaction is now driven by the backend
      # worker, so retention moved to `backend_worker.compaction.*`
      # (tempodb.CompactorConfig), and the `v2_index_downsample_bytes` /
      # `v2_encoding` block settings no longer exist. Config predates the
      # 3.0.2 package bump and Tempo's strict decoder rejects unknown
      # fields, so it never started.
      backend_worker.compaction = {
        block_retention = "720h"; # 30 days
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
        processor = {
          service_graphs = {
            dimensions = [
              "http.method"
              "http.status_code"
            ];
          };
          span_metrics = {
            dimensions = [
              "http.method"
              "http.status_code"
            ];
          };
          # Future: semantic HTTP convention attributes
          # service_graphs = {
          #   dimensions = [
          #     "http.request.method"
          #     "http.response.status_code"
          #   ];
          # };
        };
      };
      overrides.defaults.metrics_generator.processors = ["service-graphs" "span-metrics"];
    };
  };

  services.prometheus = {
    enable = true;
    port = 9090;
    retentionTime = "45d";
    webExternalUrl = "https://homelab-otel.dropbear-butterfly.ts.net/prometheus";
    extraFlags = ["--web.route-prefix=/"];

    # The default `true` runs a full `promtool check config` at BUILD time, which
    # stats every file a scrape job references -- including the woodpecker job's
    # authorization.credentials_file at /run/agenix/woodpecker-metrics-token.
    # agenix only decrypts that during activation, so it cannot exist in the
    # build sandbox and the check fails the whole colmena build:
    #   FAILED: error checking authorization credentials or bearer token file
    #   "/run/agenix/woodpecker-metrics-token": no such file or directory
    # "syntax-only" keeps the YAML/schema validation and drops the file-existence
    # probe. Trade-off: a typo in a secret path is no longer caught at build time,
    # it surfaces as prometheus failing to start.
    checkConfig = "syntax-only";

    globalConfig = {
      scrape_interval = "30s";
      scrape_timeout = "10s";
      evaluation_interval = "30s";
      external_labels = {
        environment = "homelab";
        datacenter = "home";
      };
    };

    # Targets are addressed by their *.homelab.local names (records live in
    # hosts/dns/configuration.nix) rather than raw IPs, so a re-IP is a one-line
    # change there instead of an edit in both places.
    #
    # Note how prometheus treats those names: it does NOT re-resolve them per
    # scrape, and it has no DNS cache either. It keeps an HTTP keep-alive
    # connection per target, and DNS is only consulted when a connection is
    # actually dialed -- at startup, or after one drops. So a changed A record is
    # NOT picked up until the connection breaks or prometheus restarts; targets
    # that need to follow DNS have to use dns_sd_configs, not static_configs.
    #
    # Every job below sets `labels.instance` explicitly, which overrides the
    # instance label prometheus would otherwise derive from the target address.
    # That is what keeps this addressing change free of series churn -- do not
    # drop those labels, or every existing series is orphaned.
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
            targets = ["database.homelab.local:9100"];
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
            targets = ["database.homelab.local:9187"];
            labels = {
              instance = "homelab-database";
            };
          }
        ];
      }
      # DNS host exporters.
      #
      # Deliberately the only job still addressed by IP. Every other target here
      # is a *.homelab.local name served by unbound on this very host, so if
      # unbound dies the job that would tell you must not be behind the name it
      # can no longer resolve. Prometheus re-resolves a target only when it dials
      # a new connection (see the comment on scrape_interval below), and a dead
      # DNS host is exactly a case where the connection drops and has to be
      # re-dialed -- so a name here would go down precisely when it is needed.
      # See the DNS note above scrapeConfigs for why re-resolution is dial-time.
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
            targets = ["unifi.homelab.local:9100"];
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
            targets = ["containers.homelab.local:9100"];
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
            targets = ["containers.homelab.local:9187"];
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
            targets = ["mcp.homelab.local:9100"];
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
            targets = ["hermes.homelab.local:9100"];
            labels = {
              instance = "homelab-hermes";
            };
          }
        ];
      }
      # The k3s-server-1 / k3s-agent-1 node jobs were removed on 2026-08-15: both
      # machines are shut down and no longer deployed, and neither had reported
      # up == 1 in the preceding 30 days. They were scraped anyway, which cost
      # nothing while nothing alerted -- but the TargetDown rule added in
      # ./alerting.nix turns a permanently-absent host into a permanent page, so
      # a target that is not expected to answer has to come out of the scrape
      # list. Their host configs, flake entries and DNS records are untouched;
      # re-add a job here if either is ever redeployed.

      # CA host exporters
      {
        job_name = "ca-node";
        static_configs = [
          {
            targets = ["ca.homelab.local:9100"];
            labels = {
              instance = "homelab-ca";
            };
          }
        ];
      }
      # Cache host exporters (Garage + Attic)
      {
        job_name = "cache-node";
        static_configs = [
          {
            targets = ["cache.homelab.local:9100"];
            labels = {
              instance = "homelab-cache";
            };
          }
        ];
      }
      # Forgejo host exporters
      {
        job_name = "forgejo-node";
        static_configs = [
          {
            targets = ["forgejo.homelab.local:9100"];
            labels = {
              instance = "homelab-forgejo";
            };
          }
        ];
      }
      # Woodpecker CI host exporters
      # Scrape interval raised to 5m: CI is typically idle between pipeline runs,
      # so less frequent polling reduces overhead. Prometheus will still pick up
      # metrics when pipelines are active.
      {
        job_name = "woodpecker-node";
        scrape_interval = "5m";
        scrape_timeout = "30s";
        static_configs = [
          {
            targets = ["woodpecker.homelab.local:9100"];
            labels = {
              instance = "homelab-woodpecker";
            };
          }
        ];
      }
      # Development host exporters
      {
        job_name = "development-node";
        static_configs = [
          {
            targets = ["development.homelab.local:9100"];
            labels = {
              instance = "homelab-development";
            };
          }
        ];
      }
      # The zeroclaw-node job was removed on 2026-08-15 for the same reason as the
      # k3s jobs above: the host is shut down, last successful scrape was
      # 21.5 days earlier. Host config, flake entry and DNS record are untouched.

      # Jellyfin host exporters
      {
        job_name = "jellyfin-node";
        static_configs = [
          {
            targets = ["jellyfin.homelab.local:9100"];
            labels = {
              instance = "homelab-jellyfin";
            };
          }
        ];
      }
      # Fleet host exporters
      {
        job_name = "fleet-node";
        static_configs = [
          {
            targets = ["fleet.homelab.local:9100"];
            labels = {
              instance = "homelab-fleet";
            };
          }
        ];
      }
      # Harbor host exporters
      {
        job_name = "harbor-node";
        static_configs = [
          {
            targets = ["harbor.homelab.local:9100"];
            labels = {
              instance = "homelab-harbor";
            };
          }
        ];
      }
      # The vllm job on wotan was removed on 2026-08-15 along with the k3s and
      # zeroclaw jobs above -- that host is down too. Re-add it here when wotan
      # comes back; the endpoint was wotan.homelab.local:10808.

      # Hofvarpnir — migrated onto homelab-jellyfin; scrape its step-ca Caddy
      # vhost (otel trusts step-ca via modules/step-ca-trust.nix). Was the
      # tsbridge ts.net name on the old LXC.
      {
        job_name = "hofvarpnir";
        scheme = "https";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = ["hofvarpnir.homelab.local"];
            labels = {
              instance = "hofvarpnir";
            };
          }
        ];
      }
      # Proxmox VE hypervisor (bare-metal, not nix-managed) node_exporter.
      #
      # Use the .homelab.local name, not the bare .local one that was here
      # before: this scrape silently went to `no such host` on 2026-08-05 and
      # stayed down, which is exactly when the woodpecker ballooning needed
      # diagnosing. `.local` is mDNS-reserved, so a resolver that does not hand
      # it to unbound never sees the local-data record at all. Every other
      # target here uses .homelab.local for the same reason.
      {
        job_name = "pve-node";
        static_configs = [
          {
            targets = ["pve-gigabyte.homelab.local:9100"];
            labels = {
              instance = "pve-gigabyte";
            };
          }
        ];
      }
      # axon-gateway MCP gateway metrics. The container binds 127.0.0.1:8091 on
      # the containers host, so it is only reachable via its Caddy vhost over
      # HTTPS (step-ca cert, trusted here via modules/step-ca-trust.nix).
      {
        job_name = "axon-gateway";
        scheme = "https";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = ["axon.homelab.local"];
            labels = {
              instance = "homelab-containers";
            };
          }
        ];
      }
      # Woodpecker *application* metrics (queue depth, pending/running pipelines)
      # -- distinct from the woodpecker-node job above, which is host-level.
      #
      # Two things to know about this endpoint:
      #   1. It does not exist at all unless WOODPECKER_PROMETHEUS_AUTH_TOKEN is
      #      set on the server. No token, no /metrics -- a 404, not a 401.
      #   2. It is bearer-authenticated, and the token has to be on BOTH hosts:
      #      on woodpecker inside woodpecker-server-env.age, and here as a bare
      #      one-line file for prometheus. Hence its own .age rather than reusing
      #      the server env file, which otel has no business decrypting.
      #
      # The server binds 127.0.0.1:8000, so the only route in is its Caddy vhost
      # over HTTPS (step-ca cert, trusted here via modules/step-ca-trust.nix).
      #
      # Scrape interval raised to 5m: CI is typically idle between pipeline runs,
      # so less frequent polling reduces overhead.
      {
        job_name = "woodpecker";
        scrape_interval = "5m";
        scrape_timeout = "30s";
        scheme = "https";
        metrics_path = "/metrics";
        authorization.credentials_file = config.age.secrets.woodpecker-metrics-token.path;
        static_configs = [
          {
            targets = ["ci.homelab.local"];
            labels = {
              instance = "homelab-woodpecker";
            };
          }
        ];
      }
    ];
  };

  # Bare token, no KEY=value wrapper -- prometheus reads the whole file as the
  # bearer credential (trailing whitespace trimmed). Must be byte-identical to
  # WOODPECKER_PROMETHEUS_AUTH_TOKEN in woodpecker-server-env.age.
  age.secrets.woodpecker-metrics-token = {
    file = ../../secrets/woodpecker-metrics-token.age;
    owner = "prometheus";
    group = "prometheus";
  };

  age.secrets.grafana-secret-key = {
    file = ../../secrets/grafana-secret-key.age;
    owner = "grafana";
    group = "grafana";
  };

  age.secrets.grafana-oidc-secret = {
    file = ../../secrets/grafana-oidc-secret.age;
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
      "auth.generic_oauth" = {
        enabled = true;
        name = "Pocket-ID";
        allow_sign_up = true;
        client_id = "dba3e94b-d22d-444d-82ce-723e433e3d67";
        client_secret = "$__file{${config.age.secrets.grafana-oidc-secret.path}}";
        scopes = "openid email profile groups";
        auth_url = "https://pocketid.dropbear-butterfly.ts.net/authorize";
        token_url = "https://pocketid.dropbear-butterfly.ts.net/api/oidc/token";
        api_url = "https://pocketid.dropbear-butterfly.ts.net/api/oidc/userinfo";
        use_pkce = true;
        role_attribute_path = "contains(groups[*], 'admins') && 'Admin' || 'Viewer'";
      };
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        deleteDatasources = [
          {
            name = "Prometheus";
            orgId = 1;
          }
          {
            name = "Loki";
            orgId = 1;
          }
          {
            name = "Tempo";
            orgId = 1;
          }
        ];
        datasources = [
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
                  matcherRegex = "(?:traceID|trace_id|traceId)[=:]\\s*([a-fA-F0-9]+)";
                  url = "$${__value.raw}";
                  datasourceUid = "tempo";
                  urlDisplayLabel = "View Trace";
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
              nodeGraph.enabled = true;
              tracesToLogsV2 = {
                datasourceUid = "loki";
                spanStartTimeShift = "-1h";
                spanEndTimeShift = "1h";
                filterByTraceID = true;
                filterBySpanID = false;
              };
              tracesToMetrics = {
                datasourceUid = "prometheus";
              };
              serviceMap = {
                datasourceUid = "prometheus";
              };
              lokiSearch = {
                datasourceUid = "loki";
              };
            };
          }
        ];
      };
    };
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-otel.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle_path /prometheus* {
          reverse_proxy localhost:9090
        }

        handle /loki* {
          reverse_proxy localhost:3100
        }

        handle /tempo* {
          reverse_proxy localhost:3200
        }

        handle /grafana* {
          reverse_proxy localhost:3000
        }

        # OTLP endpoints (traces, metrics, logs)
        handle /v1/* {
          reverse_proxy localhost:4318
        }

        handle {
          respond "OK" 200
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."otel.homelab.local otel.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle_path /prometheus* {
          reverse_proxy localhost:9090
        }

        handle /loki* {
          reverse_proxy localhost:3100
        }

        handle /tempo* {
          reverse_proxy localhost:3200
        }

        handle /grafana* {
          reverse_proxy localhost:3000
        }

        # OTLP endpoints (traces, metrics, logs)
        handle /v1/* {
          reverse_proxy localhost:4318
        }

        handle {
          respond "OK" 200
        }
      '';
    };

    # Dedicated per-service hostnames (step-ca certs), each served at root
    virtualHosts."loki.homelab.local loki.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:3100
      '';
    };

    virtualHosts."tempo.homelab.local tempo.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:3200
      '';
    };

    virtualHosts."prometheus.homelab.local prometheus.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:9090
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
      9090 # Prometheus HTTP (queried by prommcp on the mcp host)
    ];
  };

  environment.systemPackages = with pkgs; [
    opentelemetry-collector-contrib
  ];
}
