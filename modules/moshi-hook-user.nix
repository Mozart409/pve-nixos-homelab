{
  config,
  pkgs,
  ...
}: let
  user = "amadeus";

  # Same shape as hosts/hermes/moshi-hook.nix, targeting the interactive
  # amadeus user instead of a service account.
  #
  # `install` wires every $HOME-scoped agent target: Claude Code
  # (~/.claude/settings.json) AND opencode
  # (~/.config/opencode/plugins/moshi-hooks.ts). Both are global as of 0.2.59 —
  # verified with `moshi-hook status`, which reports them as `current`. There is
  # no per-project step to repeat.
  #
  # These run as **user** units, not system units with User=amadeus. moshi-hook
  # derives its socket path from XDG_RUNTIME_DIR (`/run/user/1000/moshi-hook.sock`),
  # which systemd sets for user units but NOT for system units running as a user.
  # As a system unit the daemon and the hooks — which are spawned from
  # interactive shells and resolve the socket from their own environment — would
  # bind and dial different paths, and no notification would ever arrive. Linger
  # keeps the daemon up without an active login session.
  moshiPairInstall = pkgs.writeShellScript "moshi-pair-install-${user}" ''
    set -eu
    moshi=${pkgs.moshi-hook}/bin/moshi-hook

    # `moshi-hook status --json` exits 0 even when the host is UNPAIRED, so the
    # exit code is useless as a guard — it silently skipped pairing entirely and
    # left the daemon running unpaired. Test the `paired` field instead.
    if ! "$moshi" status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -e '.paired == true' >/dev/null 2>&1; then
      token="$(cat ${config.age.secrets.moshi-device-id.path})"
      if [ -z "$token" ]; then
        echo "moshi-hook-setup: moshi-device-id secret is empty" >&2
        exit 1
      fi
      "$moshi" pair --token "$token"
    fi

    # `install` skips the claude target outright when ~/.claude is absent, which
    # is the case on a freshly provisioned host where Claude Code has never run.
    # Create it first so the hooks land without a manual first launch.
    mkdir -p "$HOME/.claude"
    "$moshi" install
  '';
in {
  imports = [./moshi-hook.nix];

  # Start the user manager at boot so the daemon runs without a login session.
  users.users.${user}.linger = true;

  systemd.user.services.moshi-hook-setup = {
    description = "Pair + install Moshi hooks for ${user}";
    wantedBy = ["default.target"];
    # Fail loudly and retry rather than exiting 0 on a bad/missing token: an
    # unpaired daemon that reports success is the failure mode that hid the
    # broken hook wiring before. The retry also covers the ordering race — user
    # units are started by logind (post-multi-user), so /run/agenix should be
    # populated, but a slow activation just means a few retries instead of a
    # permanently unpaired host. Pairing persists in
    # ~/.local/state/moshi/secrets.json, so this is a first-boot cost only.
    startLimitBurst = 5;
    startLimitIntervalSec = 300;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = moshiPairInstall;
      Restart = "on-failure";
      RestartSec = 15;
    };
  };

  systemd.user.services.moshi-hook = {
    description = "Moshi agent hook daemon (${user})";
    after = ["moshi-hook-setup.service"];
    requires = ["moshi-hook-setup.service"];
    wantedBy = ["default.target"];
    serviceConfig = {
      ExecStart = "${pkgs.moshi-hook}/bin/moshi-hook serve";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
