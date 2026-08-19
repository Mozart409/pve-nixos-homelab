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
}: {
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
