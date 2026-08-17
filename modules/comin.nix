# Comin pull-based GitOps. Imported by every real host — both in
# nixosConfigurations (mkHost + explicit entries) and in colmenaHive — so a
# colmena-pushed closure and a comin-pulled closure are identical and neither
# tool removes the other.
#
# `hostname` is the FLAKE ATTRIBUTE name (e.g. "database"), NOT
# networking.hostName, which is "homelab-<name>" everywhere and has no matching
# nixosConfigurations attribute.
{
  comin,
  hostname,
}: {
  imports = [comin.nixosModules.comin];

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
}
