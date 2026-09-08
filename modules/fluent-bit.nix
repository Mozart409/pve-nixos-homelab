# The fluent-bit journald -> Loki shipper. Owns the `services.loki-logs`
# option and every piece of fluent-bit configuration; nothing else in the repo
# should touch services.fluent-bit.
#
# Imported once, fleet-wide, from modules/common.nix. It used to be reached
# transitively through modules/comin.nix, which was also the module that turned
# it on -- so deleting comin on 2026-09-08 silently disabled log shipping on
# every host that did not enable it itself. A log shipper has no business
# depending on a GitOps agent, or on modules/attic-push.nix, which briefly
# inherited the same job. Hence: one owner, imported from the one module every
# host already has.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.loki-logs;

  # ── Restart nonce ─────────────────────────────────────────────────────────
  # Same trick as hosts/hermes/configuration.nix's secretNonce: a string in the
  # unit definition that you bump to force a restart on the next apply.
  #
  # Unlike hermes-agent this unit does NOT normally need it -- ExecStart carries
  # the generated config's store path (verified 2026-09-08:
  # `--config /nix/store/...-fluent-bit.yaml`), so editing `units` already
  # changes the unit and restarts it. The nonce is the manual lever for
  # everything that path does not cover: a fluent-bit that is running but has
  # stopped delivering, a wedged journal cursor under /var/lib/fluent-bit, or
  # confirming that a host's shipper actually came back after a change.
  #
  # Bump this when you want every loki-logs host to restart its shipper.
  restartNonce = "2026-09-08-ship-fluent-bit-self";

  # fluent-bit ships its own journal, on every host, always.
  #
  # Why this is not optional: on 2026-09-08 every host was found to deliver only
  # a SUBSET of its configured units -- otel had attic-login, attic-push and
  # comin configured and shipped only attic-push; database shipped only
  # postgresql; mcp 3 of its 14. The one thing that would explain it is
  # fluent-bit's own log, and that was the single journal nobody shipped, so the
  # failure could not be diagnosed without SSH to each host.
  #
  # Feedback-loop risk is real but bounded: at log_level info fluent-bit logs
  # startup, config and errors, not one line per record or per flush. If this
  # ever does run away, the lever is service.log_level below, not removing this.
  selfUnit = {
    unit = "fluent-bit.service";
    job = "fluent-bit";
  };

  shippedUnits = cfg.units ++ [selfUnit];

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

    # See restartNonce above.
    systemd.services.fluent-bit.restartTriggers = [restartNonce];

    services.fluent-bit = {
      enable = true;
      settings = {
        service = {
          flush = 5;
          log_level = "info";
        };

        pipeline = {
          inputs = map mkInput shippedUnits;
          outputs = map mkOutput shippedUnits;
        };
      };
    };
  };
}
