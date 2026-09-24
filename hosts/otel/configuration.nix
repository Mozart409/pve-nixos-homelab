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
    ../../modules/loki.nix
    ../../modules/caddy-http3.nix
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
        # Kept defined but wired into no pipeline. With `debug` on every
        # pipeline the collector printed a line per batch (5s timeout) to
        # stdout -> journald -> fluent-bit -> Loki, i.e. every trace batch
        # from hofvarpnir cost this IO-starved host two extra disk writes plus
        # a Loki ingest of its own chatter (2026-09-13 audit: the bulk of the
        # 120-300 lines/5min otel was shipping). Re-add `debug` to a pipeline's
        # exporters list only while actually debugging that pipeline.
        debug:
          verbosity: basic

        # Metrics: nothing sends OTLP metrics (the collector has never even
        # registered otelcol_receiver_accepted_metric_points), and a pipeline
        # must name at least one exporter. `nop` keeps the OTLP metrics
        # endpoint answering without turning `debug` back on.
        nop: {}

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
          # `debug` deliberately absent from every pipeline -- see the
          # exporters block above.
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [nop]
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/loki]
    '';
  };

  systemd.services.otel-collector = {
    description = "OpenTelemetry Collector";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    # ExecStart reads /etc/otelcol/config.yaml -- a stable path -- so a config
    # edit changes the etc file but not the unit, and switch-to-configuration
    # leaves the old process running with the old pipelines (2026-09-13: the
    # debug-exporter removal deployed "successfully" while the collector kept
    # its 4-day uptime). Trigger on the store path of the generated file, the
    # same idiom as AGENTS.md §5's secretNonce / axon-gateway CONFIG_HASH.
    restartTriggers = [config.environment.etc."otelcol/config.yaml".source];
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

  # Tempo for distributed tracing
  #
  # tempo.service's journal was shipped to the central Loki from 2026-09-08
  # while the unit sat in `failed` (otel is unreachable by SSH from the
  # development host, so the log had to come out through Loki). That
  # diagnostic did its job -- the read-only /var/tempo path below was found and
  # fixed -- and was retired 2026-09-13: a healthy Tempo logs ~2,300 lines/h
  # of block-cut / compaction / scheduler-poll chatter, and on this
  # IO-starved host every one of those lines was a journald write, a
  # fluent-bit read, an HTTPS push to the local Caddy and a Loki ingest.
  # Nothing else on otel ships to Loki; if Tempo misbehaves again, re-add
  #   services.loki-logs.units = [ { unit = "tempo.service"; job = "tempo"; } ];
  # here (modules/fluent-bit.nix enables the shipper fleet-wide, the units
  # list merges across modules).

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
      # `v2_encoding` block settings no longer exist.
      #
      # This block is correct and was never the reason tempo stayed down --
      # `tempo -config.verify` accepts it (checked 2026-09-08, with a
      # deliberately bogus key as a control to prove verify really does reject
      # unknown fields). The actual cause is the read-only path problem
      # described below.
      backend_worker.compaction = {
        block_retention = "720h"; # 30 days
      };

      # Tempo 3.x split ingestion into new modules -- live-store, block-builder
      # and backend-scheduler -- and every one of them defaults its paths under
      # /var/tempo. That directory is unwritable here: the unit runs with
      # DynamicUser = true, which implies ProtectSystem = strict, so the only
      # writable location is the StateDirectory at /var/lib/tempo. Result was
      #   module=live-store err="... failed to create shutdown marker
      #   directory: mkdir /var/tempo: read-only file system"
      # and distributor/querier/metrics-generator/backend-scheduler all
      # cascade-failing off it, leaving tempo.service in `failed` -- which is
      # what made every `colmena apply --on otel` exit 4, and what served the
      # 502 on tempo.homelab.local.
      #
      # NB the older comment above blamed a 3.0 schema mismatch. That was
      # wrong: the previous config passes `tempo -config.verify` cleanly
      # (checked 2026-09-08). The decoder was never the problem; the read-only
      # path was. storage.trace.wal.path below was already redirected, which is
      # why only the NEW modules broke.
      live_store = {
        shutdown_marker_dir = "/var/lib/tempo/live-store/shutdown-marker";
        wal.path = "/var/lib/tempo/live-store/traces";

        # Block cadence. Tempo 3.0.3's live-store defaults to
        # max_block_duration = 30s / max_block_bytes = 50MB
        # (modules/livestore/config.go), i.e. a block is cut every 30 s no
        # matter how little arrived. At this lab's ~0.3 spans/s that meant ~105
        # blocks/h of ~95 KB each, then ~50 compactions/h and ~350 deletes/h
        # to fold them back together (2026-09-13 journal audit) -- hundreds of
        # directory creates, parquet writes, fsyncs and unlinks per hour on a
        # zvol that lives on the saturated HDD mirror. 30 min collapses that to
        # ~2 blocks/h; the 50MB byte ceiling still cuts early under real load.
        # Cost: a fresh trace is queryable from the live block either way, so
        # nothing user-visible changes. Validation only requires > 0.
        max_block_duration = "30m";
      };

      # The backend-worker long-polls the scheduler for compaction jobs and,
      # finding none, logs a gRPC warn + an "error calling scheduler" error and
      # backs off -- capped at 1m by default, so ~90 log lines/h of nothing.
      # With blocks cut every 30 min there is rarely a job; poll less often.
      backend_worker.backoff.max_period = "10m";
      block_builder.wal.path = "/var/lib/tempo/block-builder/traces";
      backend_scheduler.local_work_path = "/var/lib/tempo/backend-scheduler";
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
    extraFlags = [
      "--web.route-prefix=/"
      # Tempo's metrics-generator (services.tempo.settings.metrics_generator
      # above) remote-writes service-graph and span-metrics series here. Without
      # this flag Prometheus answers 404 and Tempo logged
      #   non-recoverable error ... url=http://localhost:9090/api/v1/write
      #   failedSampleCount=369 ... remote write receiver needs to be enabled
      # once a minute since the generator was configured -- every sample spooled
      # through /var/lib/tempo/generator/wal and then dropped (found 2026-09-13).
      # Loopback only: 9090 is opened in the firewall for prom-mcp, but the
      # receiver accepts unauthenticated writes, so keep this host's 9090 off
      # anything but the LAN.
      "--web.enable-remote-write-receiver"
    ];

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
      # (containers-postgres, the exporter for uptime-forge's TimescaleDB,
      # was dropped 2026-09-12 with the service.)
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
      # (The cache-node job lived here until 2026-09-09, when the cache VM was
      # decommissioned -- see iac/main.tf. Removing the target is what silences
      # its alerting: alerting.nix has no cache-specific rules, only generic
      # up/cert ones driven by the targets in this file and blackbox.nix.)
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
      # hermes-node came BACK with the 2026-09 rebuild of that host
      # (docs/plans/hermes-rebuild.md). Node exporter on 9100 is one of the
      # three ports its firewall opens; the api_server and its blackbox probes
      # are gone for good, so do not re-add those to ./blackbox.nix.
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
      # Removed on 2026-09-10, for the same reason as the 2026-08-15 note above:
      # homelab-harbor, homelab-woodpecker, homelab-fleet and
      # homelab-k3s-cntrl-1 are all deliberately shut down and are not expected
      # back. Their node jobs (harbor-node, woodpecker-node, fleet-node,
      # k3s-cntrl-1-node), the woodpecker application job, and their
      # http_2xx probes in ./blackbox.nix were scraped anyway, which left
      # TargetDown and ProbeFailed firing permanently -- nine standing alerts,
      # and a board that is always red is a board you stop reading. Host configs,
      # flake entries, DNS records and the woodpecker-metrics-token secret are
      # untouched; re-add the jobs here and the probes there if any of these
      # hosts is redeployed.

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
              # Moved from containers to the mcp host on 2026-09-14.
              instance = "homelab-mcp";
            };
          }
        ];
      }
    ];
  };

  # Bare token, no KEY=value wrapper -- prometheus reads the whole file as the
  # bearer credential (trailing whitespace trimmed). Must be byte-identical to
  # WOODPECKER_PROMETHEUS_AUTH_TOKEN in woodpecker-server-env.age.
  #
  # Nothing reads this since the woodpecker job was removed on 2026-09-10, and
  # it is kept deliberately: the token is the fiddly half of that job (it has
  # to match on both hosts, and without it the endpoint 404s rather than 401s),
  # so re-adding the scrape config should not also mean re-deriving this.
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

  # Break-glass local admin. Grafana is OIDC-only in the UI (auth block
  # below); this password exists so `grafana-cli admin reset-admin-password`
  # / the HTTP API still work if Pocket ID is down. Was the literal "admin"
  # until 2026-09-14, which the audit confirmed logged in over the LAN.
  age.secrets.grafana-admin-password = {
    file = ../../secrets/grafana-admin-password.age;
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
        admin_password = "$__file{${config.age.secrets.grafana-admin-password.path}}";
        secret_key = "$__file{${config.age.secrets.grafana-secret-key.path}}";
      };
      # OIDC is the only interactive login: the username/password form is gone
      # and the UI bounces straight to Pocket ID. HTTP basic auth stays on
      # deliberately -- it is the break-glass path (`curl -u admin:<pw>
      # …/grafana/api/…` from a host that can decrypt the secret) when Pocket
      # ID is down, and with a random 32-char password it is no longer the
      # hole it was with "admin".
      auth = {
        disable_login_form = true;
        oauth_auto_login = true;
      };
      users.allow_sign_up = false;
      "auth.generic_oauth" = {
        enabled = true;
        name = "Pocket-ID";
        # Existing Grafana accounts only. A Pocket ID user without a Grafana
        # account is refused; create it in the Grafana UI first (or flip this
        # for one login and back).
        allow_sign_up = false;
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

  # Bearer tokens that gate the push and log/trace-read paths on this host.
  # Until 2026-09-14 prometheus (remote-write receiver included), loki, tempo,
  # alertmanager and the OTLP receiver were reachable by anyone on the LAN or
  # tailnet with no credential at all -- and loki held the postgres role
  # passwords (see hosts/database, mkRolePasswordUnit). Two tokens, two blast
  # radii:
  #   push  -- every host's fluent-bit (modules/fluent-bit.nix) and OTLP
  #            senders. Encrypted to every host key, so it is the one that
  #            leaks when any single VM does; it can only *write*.
  #   query -- the read side: the loki/tempo MCP servers on the mcp host.
  #            Only otel + mcp can decrypt it.
  # Both are bare tokens (no KEY=value): Caddy reads them with the {file.…}
  # placeholder, fluent-bit and the MCP servers get them via LoadCredential.
  # Grafana reads all three stores over loopback and is unaffected.
  #
  # Prometheus and Alertmanager are deliberately NOT gated: their own UIs are
  # the point of having them, and a browser cannot attach a bearer token, so
  # gating them meant every link had to bounce to Grafana instead. Both still
  # bind loopback only -- Caddy on 443 remains the one way in, and the raw
  # ports stay closed in the firewall below.
  age.secrets.otel-push-token = {
    file = ../../secrets/otel-push-token.age;
    owner = "caddy";
    group = "caddy";
    mode = "0400";
  };
  age.secrets.otel-query-token = {
    file = ../../secrets/otel-query-token.age;
    owner = "caddy";
    group = "caddy";
    mode = "0400";
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = let
    pushToken = "{file.${config.age.secrets.otel-push-token.path}}";
    queryToken = "{file.${config.age.secrets.otel-query-token.path}}";
    # Named matchers, declared once per site and referenced by the handles.
    # `header` matcher values take placeholders, so the comparison is against
    # the live secret file, not a token baked into the Caddyfile in /nix/store.
    authMatchers = ''
      @push header Authorization "Bearer ${pushToken}"
      @query header Authorization "Bearer ${queryToken}"
    '';
    # The otel.homelab.local / ts.net "everything on one name" sites. Grafana
    # (its own OIDC login) and prometheus stay open; loki, tempo and the OTLP
    # receiver need a token. Loki's push path takes either token so a host that
    # only holds the push token can ship logs; reads need the query token.
    aggregate = ''
      ${authMatchers}
      @lokiPush {
        path /loki/api/v1/push
        header Authorization "Bearer ${pushToken}"
      }

      handle /grafana* {
        reverse_proxy localhost:3000
      }
      # `handle` blocks are mutually exclusive and sorted by path length; the
      # inner `route` keeps the written order so the token check runs before
      # the 401 fallback (reverse_proxy does not fall through once matched).
      handle /v1/* {
        route {
          reverse_proxy @push localhost:4318
          respond 401
        }
      }
      # Open -- see the token comment above. No `route` needed once there is
      # no 401 fallback to order against.
      handle /prometheus* {
        uri strip_prefix /prometheus
        reverse_proxy localhost:9090
      }
      handle /loki* {
        route {
          reverse_proxy @lokiPush localhost:3100
          reverse_proxy @query localhost:3100
          respond 401
        }
      }
      handle /tempo* {
        route {
          reverse_proxy @query localhost:3200
          respond 401
        }
      }
      handle {
        respond "OK" 200
      }
    '';
    # Ungated single-service vhost: the service's own UI, reachable from a
    # browser. Used for prometheus (and, in ./alerting.nix, alertmanager).
    open = port: ''
      tls {
        ca https://ca.homelab.local:8443/acme/acme/directory
      }
      reverse_proxy localhost:${toString port}
    '';
    # Single-service vhosts: the query token unlocks everything; on loki the
    # push token additionally unlocks the push path (that is what every
    # host's fluent-bit uses). Everything sits in one `route` because Caddy
    # otherwise orders a bare `reverse_proxy` AFTER `route`, which would let
    # the 401 fallback win for push requests.
    single = port: withPush: ''
      tls {
        ca https://ca.homelab.local:8443/acme/acme/directory
      }
      ${authMatchers}
      ${lib.optionalString withPush ''
        @lokiPush {
          path /loki/api/v1/push
          header Authorization "Bearer ${pushToken}"
        }
      ''}
      route {
        ${lib.optionalString withPush "reverse_proxy @lokiPush localhost:${toString port}"}
        reverse_proxy @query localhost:${toString port}
        respond 401
      }
    '';
  in {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-otel.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }
        ${aggregate}
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."otel.homelab.local otel.homelab.internal" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }
        ${aggregate}
      '';
    };

    # Dedicated per-service hostnames (step-ca certs), each served at root
    virtualHosts."loki.homelab.local loki.homelab.internal" = {
      extraConfig = single 3100 true;
    };

    virtualHosts."tempo.homelab.local tempo.homelab.internal" = {
      extraConfig = single 3200 false;
    };

    virtualHosts."prometheus.homelab.local prometheus.homelab.internal" = {
      extraConfig = open 9090;
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
      443 # HTTPS (Caddy) -- the only way in; everything below it is token-gated
      # 9090/3100/3200/8888/4317/4318 are deliberately NOT here any more
      # (closed 2026-09-14). Prometheus, Loki, Tempo, the collector's own
      # metrics and both OTLP receivers still bind 0.0.0.0, but only loopback
      # (grafana, tempo remote_write, the alertmanager bridge) and the one
      # source-scoped exception below can reach them.
    ];
    # hofvarpnir (jellyfin host) speaks OTLP/gRPC to 4317 and pushes logs to
    # Loki's raw 3100 with no way to attach a bearer token, so those two ports
    # stay open to that single source address. Everything else goes through
    # Caddy. Drop this once hofvarpnir can send `Authorization` headers and
    # hosts/jellyfin/hofvarpnir.nix points it at the vhosts.
    extraCommands = ''
      iptables -A nixos-fw -p tcp -s 192.168.2.180 --dport 4317 -j nixos-fw-accept
      iptables -A nixos-fw -p tcp -s 192.168.2.180 --dport 3100 -j nixos-fw-accept
    '';
  };

  environment.systemPackages = with pkgs; [
    opentelemetry-collector-contrib
  ];
}
