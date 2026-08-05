{
  config,
  lib,
  ...
}: let
  cfg = config.services.loki-logs;

  # One journald input per requested unit. `tag` is set to the unit's Loki job
  # name so the matching output below can route on it (fluent-bit's loki output
  # selects records by tag via `match`).
  mkInput = u: {
    name = "systemd";
    tag = u.job;
    systemd_filter = "_SYSTEMD_UNIT=${u.unit}";
    # Cursor DB so restarts resume where the last record left off instead of
    # re-shipping history. Lives under the StateDirectory declared below.
    db = "/var/lib/fluent-bit/${u.job}-journal.db";
    # Start at the END of the journal on first run. Without this, the first
    # boot ships the ENTIRE journal history (potentially months of logs) into
    # Loki in one burst.
    read_from_tail = true;
  };

  mkOutput = u: {
    name = "loki";
    match = u.job;
    # loki.homelab.local is a Caddy vhost on the otel host that reverse-proxies
    # at root to Loki's localhost:3100. Its TLS cert comes from step-ca, which
    # is trusted on every host importing modules/step-ca-trust.nix — so any
    # consumer of this module must also import that (hosts here already do).
    host = "loki.homelab.local";
    port = 443;
    tls = "on";
    "tls.verify" = "on";
    uri = "/loki/api/v1/push";
    # Static labels only (job, host). Journal fields (_SYSTEMD_UNIT, PRIORITY,
    # MESSAGE, ...) stay in the JSON body rather than becoming per-message Loki
    # labels — label cardinality is Loki's scarcest resource, and an unbounded
    # set of journal fields as labels would blow it up. Query the body fields
    # with LogQL `| json` instead (e.g. `{job="atticd"} | json PRIORITY="3"`).
    labels = "job=${u.job},host=${config.networking.hostName}";
    line_format = "json";
  };
in {
  options.services.loki-logs = {
    enable = lib.mkEnableOption "shipping journald logs for selected systemd units to the homelab's central Loki";

    units = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          unit = lib.mkOption {
            type = lib.types.str;
            description = "systemd unit whose journal to ship, e.g. \"atticd.service\"";
          };
          job = lib.mkOption {
            type = lib.types.str;
            description = "Loki `job` label for this unit's stream";
          };
        };
      });
      default = [];
      description = "Journald units to ship to the central Loki.";
    };
  };

  config = lib.mkIf cfg.enable {
    # fluent-bit ships the host's journald logs to the central Loki. Why fluent-bit
    # and not promtail: promtail reached EOL upstream and `services.promtail` was
    # removed from this nixpkgs pin. fluent-bit is the repo's established Loki
    # shipper — first used on zeroclaw (hosts/zeroclaw/zeroclaw/default.nix) to tail
    # a JSONL file; this module is the journald variant of the same pattern.
    #
    # Journal access needs no user plumbing: the NixOS fluent-bit module in this
    # nixpkgs pin already runs the unit as DynamicUser = true with
    # SupplementaryGroups = "systemd-journal" built in, so it can read the
    # journald files out of the box.
    #
    # WARNING (carried over from the zeroclaw config): the Nix structure below is
    # validated by `colmena build`, but fluent-bit's own YAML plugin schema is NOT
    # validated at build time — a wrong field name only surfaces at runtime on the
    # deployed host. After deploying, check `systemctl status fluent-bit` /
    # `journalctl -u fluent-bit` and confirm streams arrive in Loki.

    # The upstream module ships no StateDirectory, but the journald input's cursor
    # DBs (db = ... below) need writable state to persist read positions across
    # restarts. DynamicUser + StateDirectory gives the service /var/lib/fluent-bit
    # owned by its dynamic user.
    systemd.services.fluent-bit.serviceConfig.StateDirectory = "fluent-bit";

    services.fluent-bit = {
      enable = true;
      settings = {
        service = {
          flush = 5;
          log_level = "info";
        };

        pipeline = {
          inputs = map mkInput cfg.units;
          outputs = map mkOutput cfg.units;
        };
      };
    };
  };
}
