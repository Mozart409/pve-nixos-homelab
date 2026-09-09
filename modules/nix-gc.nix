{...}: {
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Pressure-triggered GC alongside the weekly calendar job above. The weekly
  # job only prunes generations older than 7 days, so it does nothing about
  # garbage produced *today* — repeated colmena applies
  # rebuilds every host on each poll where main has moved, which can pile up
  # same-day garbage far faster than a weekly job reacts to. min-free/max-free
  # make Nix run GC mid-build whenever free space drops below min-free, and
  # collect back up to max-free, regardless of age.
  #
  # Values raised from 1 GiB / 3 GiB after ca hit "No space left on device"
  # during a colmena push (2026-09-09). At 1 GiB min-free the copy already needs
  # temp space for lock files and nars, so the disk was full before GC could
  # trigger. 5 GiB gives nix enough headroom to start a GC before the push phase
  # chokes; 10 GiB means each triggered GC actually frees meaningful space.
  nix.settings = {
    min-free = 5 * 1024 * 1024 * 1024; # 5 GiB — GC fires before disk is critical
    max-free = 10 * 1024 * 1024 * 1024; # 10 GiB — each GC frees enough to survive the next push
  };

  nix.optimise.automatic = true;
}
