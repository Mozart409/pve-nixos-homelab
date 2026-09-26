{config, ...}: let
  # How many system generations survive a GC run, current one included.
  # Enough to roll back a couple of bad deploys; each one pins a full closure,
  # so every extra generation costs GBs on these 31 GiB root disks.
  keepGenerations = 5;
in {
  # Daily GC, bounded by count AND age.
  #
  # Age alone (the old weekly `--delete-older-than 7d`) cannot bound disk use:
  # with flake updates deploying several times a week, every generation is
  # younger than the cutoff and the job deletes nothing. Audited 2026-09-26 on
  # otel: 9 generations, all < 7 days old, /nix/store 26 GiB of a 31 GiB disk
  # (86%), and those generations were its only GC roots. containers was at 85%.
  #
  # So first trim the system profile to its newest `keepGenerations` (whatever
  # their age), then let nix-collect-garbage drop anything older than 3 days
  # from every profile (per-user, home-manager) and sweep the unreachable paths.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
    # Every VM sits on the same two-HDD zfs_pool (see pve storage notes), and
    # a GC is a burst of metadata I/O -- spread the fleet out instead of
    # having a dozen hosts start at 00:00 together. `persistent` (default
    # true) still catches up a run missed while the host was down.
    randomizedDelaySec = "2h";
  };

  systemd.services.nix-gc = {
    preStart = ''
      ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system \
        --delete-generations +${toString keepGenerations}
    '';
    # Store deletion on the shared HDD pool is pure iowait; stay out of the
    # way of the services actually running on the host.
    serviceConfig = {
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  # Pressure-triggered GC alongside the daily job above. min-free/max-free
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
