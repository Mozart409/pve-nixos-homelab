{
  config,
  pkgs,
  ...
}: let
  user = "amadeus";
  home = "/home/amadeus";

  # Same shape as hosts/hermes/moshi-hook.nix, targeting the interactive
  # amadeus user instead of a service account.
  #
  # NB: `install` wires Claude Code (~/.claude/settings.json) and any other
  # $HOME-scoped target. It does NOT retroactively cover OpenCode project
  # directories created later — OpenCode's hook file
  # (.opencode/plugins/moshi-hooks.ts) is project-local, not under $HOME — so
  # `moshi-hook install` must be rerun by hand from inside each new opencode
  # project directory amadeus starts using on this host.
  moshiPairInstall = pkgs.writeShellScript "moshi-pair-install-${user}" ''
    set -u
    moshi=${pkgs.moshi-hook}/bin/moshi-hook
    if ! "$moshi" status --json >/dev/null 2>&1; then
      token="$(cat ${config.age.secrets.moshi-device-id.path} 2>/dev/null)"
      if [ -z "$token" ]; then
        echo "moshi-hook-setup: moshi-device-id secret unreadable, skipping" >&2
        exit 0
      fi
      if ! "$moshi" pair --token "$token"; then
        echo "moshi-hook-setup: pair failed (network/token?)" >&2
        exit 0
      fi
    fi
    "$moshi" install || echo "moshi-hook-setup: install failed" >&2
  '';
in {
  imports = [./moshi-hook.nix];

  systemd.services.moshi-hook-setup = {
    description = "Pair + install Moshi hooks for ${user}";
    after = ["agenix.target"];
    wants = ["agenix.target"];
    wantedBy = ["multi-user.target"];
    environment.HOME = home;
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = moshiPairInstall;
    };
  };

  systemd.services.moshi-hook = {
    description = "Moshi agent hook daemon (${user})";
    after = ["network-online.target" "moshi-hook-setup.service"];
    wants = ["network-online.target"];
    requires = ["moshi-hook-setup.service"];
    wantedBy = ["multi-user.target"];
    environment.HOME = home;
    serviceConfig = {
      User = user;
      ExecStart = "${pkgs.moshi-hook}/bin/moshi-hook serve";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
