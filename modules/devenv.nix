{pkgs, ...}: {
  # devenv (devenv.sh): per-project reproducible dev shells driven by a
  # devenv.nix. The nixpkgs package is free (Apache-2.0) so Hydra builds it,
  # but devenv bundles its own patched nix and pulls its module set at
  # `devenv shell` time -- those come prebuilt only from devenv's cachix.
  environment.systemPackages = [
    pkgs.devenv
  ];

  # devenv's own binary cache. nixpkgs declares `substituters` with mkAfter
  # and `trusted-public-keys` as a plain list (nixos/modules/config/nix.nix),
  # so this MERGES with cache.nixos.org + modules/attic-cache.nix rather than
  # replacing them -- same pattern that module uses. Without it every first
  # `devenv shell` compiles devenv's nix fork from source.
  #
  # Per-project caches (`cachix.pull` in a devenv.nix) are a different story:
  # devenv passes them as --option extra-substituters, which the daemon only
  # honours for nix.settings.trusted-users. That list is root + amadeus
  # (modules/common.nix), so the agent user gets a warning and cache.nixos.org
  # only. Deliberate -- a trusted user can feed the daemon arbitrary store
  # paths, which is exactly the boundary hosts/development draws around it.
  nix.settings = {
    substituters = ["https://devenv.cachix.org"];
    trusted-public-keys = ["devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="];
  };

  # Native auto-activation (devenv >= 2.1): on every prompt the hook runs
  # `devenv hook-should-activate` (a static binary; nothing is evaluated) and
  # only if $PWD is a project that was explicitly `devenv allow`ed does it
  # spawn `devenv shell`. Repos that still carry an .envrc are untouched, so
  # direnv and this coexist while projects migrate one at a time: drop the
  # .envrc, add a devenv.nix, `devenv allow`. Migrated projects therefore get a
  # subshell (`exit` or cd out leaves it) rather than direnv's in-place env.
  # devenv's direnvrc is deliberately NOT installed globally: it redefines
  # nix-direnv's _nix_direnv_preflight/_nix_import_env helpers and would
  # break `use flake` for every repo that has not migrated yet.
  programs.zsh.interactiveShellInit = ''
    eval "$(${pkgs.devenv}/bin/devenv hook zsh)"
  '';
  programs.bash.interactiveShellInit = ''
    eval "$(${pkgs.devenv}/bin/devenv hook bash)"
  '';

  # Reclaim old dev shells. Every `devenv shell` drops a timestamped GC root
  # under ~/.local/share/devenv/gc/, and modules/nix-gc.nix's weekly
  # nix-collect-garbage cannot touch anything those roots reach -- so without
  # this, superseded toolchains pile up in the store until someone remembers
  # `devenv gc`. That command prunes every root but the newest per project,
  # then deletes the now-unreferenced part of the old environments' closure
  # (a scoped GC over those paths, not a full store sweep).
  #
  # A user unit so it runs as whoever owns the roots: amadeus and the agent
  # both linger, so it fires for both. Sunday evening puts it a few hours
  # before nix-gc.nix's Monday-00:00 sweep, which then sees the roots gone.
  systemd.user.services.devenv-gc = {
    description = "Prune superseded devenv shells and their store paths";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.devenv}/bin/devenv --no-tui gc";
      # Store deletion on the development host's HDD mirror is pure iowait;
      # keep it out of the way of anything interactive.
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.devenv-gc = {
    description = "Weekly devenv shell garbage collection";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "Sun *-*-* 20:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
