# Comin pull-based GitOps. Imported by every real host — both in
# nixosConfigurations (mkHost + explicit entries) and in colmenaHive — so a
# colmena-pushed closure and a comin-pulled closure are identical and neither
# tool removes the other.
#
# `hostname` is the FLAKE ATTRIBUTE name (e.g. "database"), NOT
# networking.hostName, which is "homelab-<name>" everywhere and has no matching
# nixosConfigurations attribute.
#
# Also pulls in ./attic-push.nix: every host comin can deploy to should also
# push what it builds back to the shared cache (see that file for why), and
# this is the one import point common to all of them.
{
  comin,
  hostname,
}: let
  # comin has no jitter/stagger option -- `poller.period` is a flat number,
  # and every comin host polls independently on its own uncoordinated timer
  # started at its own boot/activation time. With ~15 hive hosts all on the
  # 60s default, that's ~15 git-fetch requests/minute at forgejo, and because
  # nothing staggers them they can drift into phase and hit it in the same
  # few seconds. That's what turned a routine deploy into a 09:52-10:05 CEST
  # burst of DNS/forgejo pull failures across six hosts on 2026-08-20 (see
  # docs/deployment-status-2026-08-20.md). Giving each host a distinct period
  # makes them drift apart over time instead of staying in phase. Values are
  # arbitrary -- what matters is that every live host has a different one.
  pollerPeriods = {
    ca = 60;
    cache = 65;
    containers = 70;
    database = 75;
    development = 80;
    dns = 85;
    fleet = 90;
    forgejo = 95;
    harbor = 100;
    hermes = 105;
    jellyfin = 110;
    mcp = 115;
    otel = 120;
    unifi = 125;
    woodpecker = 130;
  };
  pollerPeriod = pollerPeriods.${hostname} or 60;
in {
  imports = [comin.nixosModules.comin ./attic-push.nix ./loki-logs.nix];

  # ── comin never restarts itself on a deploy ───────────────────────────────
  # The upstream module sets restartIfChanged = false on comin.service (visible
  # as X-RestartIfChanged=false in the generated unit), deliberately: comin runs
  # switch-to-configuration itself, and a unit that restarts mid-switch would
  # kill the deploy it is performing.
  #
  # The cost is that NOTHING in this block takes effect from a deploy alone.
  # comin keeps running its old process with its old /nix/store/...-comin.yaml
  # until someone restarts it by hand. On 2026-09-08 otel was found still
  # running the process started 2026-08-19 -- 20 days and many applies later --
  # with comin_last_eval_failed stuck at 1 and its journal showing nothing but
  # "New commits have been fetched". A plain `systemctl restart comin` loaded
  # the new config and cleared the flag immediately; no eval had to run. So the
  # stall was a wedged long-lived process, the same failure mode as caddy's
  # in-process ACME backoff and fluent-bit's dropped streams.
  #
  # NOTE the restartTriggers/nonce trick used in modules/caddy-http3.nix and
  # hosts/hermes/configuration.nix does NOT work here: restartTriggers are only
  # consulted when restartIfChanged is true, so they are silently ignored on
  # this unit. Forcing restartIfChanged = true would reintroduce exactly the
  # mid-deploy self-kill upstream is avoiding.
  #
  # AFTER CHANGING ANYTHING BELOW, run `systemctl restart comin` on the affected
  # hosts, or the change is inert. Verify with the builder line in its journal,
  # which prints the values actually in use:
  #   builder: initialization with ... evalTimeout=..., buildTimeout=...
  services.comin = {
    enable = true;
    inherit hostname;

    # comin already serves its own metrics (deploy/fetch/eval/build outcomes)
    # on :4243 of every interface -- listen_address defaults to "" -- but
    # openFirewall defaults to false, so nothing could ever reach them and
    # `{__name__=~"comin.*"}` was empty fleet-wide.
    #
    # That gap is not academic. On 2026-09-07 comin on otel had deployed
    # nothing for 7.34 days while comin.service sat `active` and the host was
    # healthy; with no comin metrics and no SSH (tailnet ACL) the stall was
    # only detectable by inferring it from
    # prometheus_config_last_reload_success_timestamp_seconds. comin_* makes
    # that a first-class signal instead of a deduction.
    #
    # Opened here rather than in each host's allowedTCPPorts -- where port 9100
    # is repeated in 15 separate host files -- because this module is the one
    # import point every comin host shares, so running comin now implies
    # exporting comin metrics, with no per-host step to forget.
    exporter.openFirewall = true;

    # Eval budget, raised from the 1800s default for the two hosts that need
    # it. Scope matters here: comin is NOT broken fleet-wide. On 2026-09-08
    # containers, jellyfin and unifi were all on the same recent commit with
    # comin_last_eval_failed = 0, having self-deployed normally. Only otel
    # (stuck on e25e70a0 from 2026-08-17) and ca had the eval flag set.
    #
    # What justifies the raise is otel's own record in
    # /var/lib/comin/store.json: its last successful deployment shows
    # eval_started_at 17:31:31 -> eval_ended_at 17:55:42, i.e. 1451s, already
    # 80% of the 1800s budget, on a flake that has grown since. Since most
    # hosts evaluate the same flake well inside the budget, slow eval is a
    # per-host resource problem -- otel and ca being the constrained ones --
    # not a property of the flake. Raising the ceiling costs nothing on hosts
    # that never approach it.
    #
    # Treat this as a mitigation whose premise is unconfirmed: the debug flag
    # below is what will actually name the cause.
    evalTimeout = 3600;
    buildTimeout = 3600;

    # Comin logs NOTHING at info level when an eval fails -- otel's journal
    # shows only "New commits have been fetched", repeatedly, since 2026-08-19
    # while comin_last_eval_failed stayed 1. That silence is why the stall went
    # undiagnosed and had to be reconstructed from store.json. Debug logging
    # makes the next failure name itself. comin is very low-volume and its
    # journal now ships to Loki (see services.loki-logs below), so enabling
    # this everywhere is cheap -- narrow it to otel/ca or drop it once the
    # cause is known.
    debug = true;

    remotes = [
      {
        name = "origin";
        # Canonical remote. Anonymously cloneable over HTTPS and step-ca
        # trusted on every host (modules/step-ca-trust.nix), so no auth secret
        # is needed. The GitHub mirror is deliberately NOT a second remote: it
        # lags main, and comin picks the newest main commit across remotes.
        url = "https://forgejo.homelab.local/amadeus/pve-nixos-homelab.git";
        # operation defaults to "switch" (merge = deploy). Per-host testing
        # branches (testing-<hostname>, operation "test") stay available.
        branches.main.name = "main";
        poller.period = pollerPeriod;
      }
    ];
  };

  # Ship comin's own journal to the central Loki. This is the one import point
  # common to every comin host, so `comin status`-equivalent visibility (fetch/
  # eval/deploy results, the eval-failed-under-memory-pressure pattern from
  # 2026-08-19) is queryable centrally instead of needing SSH per host. See
  # ./attic-push.nix for the matching attic-login/attic-push-system units.
  services.loki-logs = {
    enable = true;
    units = [
      {
        unit = "comin.service";
        job = "comin";
      }
    ];
  };
}
