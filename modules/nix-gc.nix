{...}: {
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Pressure-triggered GC alongside the weekly calendar job above. The weekly
  # job only prunes generations older than 7 days, so it does nothing about
  # garbage produced *today* — comin (pull-based GitOps, modules/comin.nix)
  # rebuilds every host on each poll where main has moved, which can pile up
  # same-day garbage far faster than a weekly job reacts to. min-free/max-free
  # make Nix run GC mid-build whenever free space drops below min-free, and
  # collect back up to max-free, regardless of age.
  nix.settings = {
    min-free = 1 * 1024 * 1024 * 1024; # 1 GiB
    max-free = 3 * 1024 * 1024 * 1024; # 3 GiB
  };

  nix.optimise.automatic = true;
}
