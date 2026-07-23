{...}: let
  dataDir = "/var/lib/zeroclaw";
in {
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
  ];

  virtualisation.oci-containers.containers.zeroclaw = {
    # Pin to the latest stable release (v0.8.3, 2026-07-16) — never :latest.
    image = "ghcr.io/zeroclaw-labs/zeroclaw:v0.8.3";
    autoStart = true;
    ports = ["127.0.0.1:42617:42617"];
    volumes = ["${dataDir}:/zeroclaw-data"];
  };

  # Ship ZeroClaw's structured JSONL runtime log to the homelab's central Loki. ZeroClaw has
  # no Prometheus /metrics endpoint and no OTLP trace exporter — this JSONL file (documented
  # in zeroclaw's own docs, ops/observability.md) is the only telemetry surface available.
  #
  # `services.promtail` was removed from this nixpkgs pin (promtail reached EOL upstream).
  # Using fluent-bit instead (services.fluent-bit.enable, still available) — it's the closer
  # single-purpose match for "tail one file, push to Loki" vs. the heavier grafana-alloy, and
  # this is the first log-shipper of either kind in the repo. Runs as systemd DynamicUser, so
  # it only works if the JSONL file ends up world-readable under rootful podman — same open
  # question flagged for post-deploy verification as the file's exact path (see dataDir glob
  # below): confirm with `systemctl status fluent-bit` + check Loki for arriving `job=zeroclaw`
  # entries once the container has actually run and written a log line.
  #
  # NOTE: unlike the Nix structure (validated by `colmena build`), fluent-bit's own YAML
  # plugin schema is NOT validated at build time — a wrong field name here would only surface
  # at runtime on the deployed host.
  systemd.services.fluent-bit.serviceConfig.StateDirectory = "fluent-bit";

  services.fluent-bit = {
    enable = true;
    settings = {
      service = {
        flush = 5;
        log_level = "info";
      };

      parsers = [
        {
          name = "zeroclaw_json";
          format = "json";
          time_key = "@timestamp";
          time_format = "%Y-%m-%dT%H:%M:%S.%L%z";
          time_keep = "on";
        }
      ];

      pipeline = {
        inputs = [
          {
            name = "tail";
            path = "${dataDir}/**/runtime-trace.jsonl";
            path_key = "filename";
            db = "/var/lib/fluent-bit/zeroclaw-tail.db";
            read_from_head = true;
            parser = "zeroclaw_json";
          }
        ];

        outputs = [
          {
            name = "loki";
            match = "*";
            host = "loki.homelab.local";
            port = 443;
            tls = "on";
            "tls.verify" = "on";
            uri = "/loki/api/v1/push";
            # Static labels only — the parsed zeroclaw.agent_alias/channel/severity_text
            # fields stay in the JSON body (line_format = json, the plugin default) rather
            # than becoming per-message Loki labels, to avoid label-cardinality blowup;
            # query them via LogQL `| json` instead.
            labels = "job=zeroclaw,host=homelab-zeroclaw";
            line_format = "json";
          }
        ];
      };
    };
  };
}
