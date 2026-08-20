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

  services.comin = {
    enable = true;
    inherit hostname;
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
