{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (config.homelab.codingHarness) user;

  # Both logins that drive coding agents on this host: the unattended `agent`
  # service account and the interactive human. Each gets its OWN daemon,
  # pairing and hook wiring -- Moshi keys a device registration to the daemon,
  # so the two appear as two hosts in the app and a notification is routed back
  # to the session that raised it. Scoping this to `agent` alone was the reason
  # notifications from Claude Code run as amadeus went nowhere: the hooks were
  # installed in ~/.claude/settings.json but no daemon ever bound a socket for
  # uid 1000.
  hookUsers = [user "amadeus"];

  # systemd.user units are installed once, into /etc/systemd/user, and loaded by
  # EVERY user manager on the host -- so each unit has to gate itself on who is
  # running it. Repeated ConditionUser= lines are ANDed (and would then hold for
  # nobody); the `|` prefix turns them into a trigger group, i.e. OR.
  conditionUsers = map (u: "|${u}") hookUsers;

  # Pin the control socket instead of letting moshi-hook derive it.
  #
  # Unset XDG_RUNTIME_DIR makes it fall back to a bare /tmp/moshi-hook.sock,
  # and this session's shells DO run without one -- `moshi-hook status` as
  # amadeus reported exactly that path. With two daemons on one host that
  # fallback is not merely wrong, it is a collision: whichever daemon started
  # first owns /tmp/moshi-hook.sock and the other user's hooks would report
  # into the wrong phone session. %t is the user manager's XDG_RUNTIME_DIR
  # (/run/user/<uid>), so the daemons stay one per uid, and the shell export
  # below hands the hooks the same path from any environment.
  socketUnit = "%t/moshi-hook.sock";
  socketShell = ''/run/user/$(${pkgs.coreutils}/bin/id -u)/moshi-hook.sock'';

  # `install` wires every $HOME-scoped agent target: Claude Code
  # (~/.claude/settings.json) AND opencode
  # (~/.config/opencode/plugins/moshi-hooks.ts). Both are global as of 0.2.59 --
  # verified with `moshi-hook status`, which reports them as `current`. There is
  # no per-project step to repeat.
  #
  # These run as **user** units, not system units with User=<login>. The daemon
  # and the hooks -- which are spawned from interactive shells -- must agree on
  # the socket, and only a user unit gets an XDG_RUNTIME_DIR at all. Linger
  # keeps both daemons up without an active login session.
  moshiPairInstall = pkgs.writeShellScript "moshi-pair-install" ''
    set -eu
    moshi=${pkgs.moshi-hook}/bin/moshi-hook

    # `moshi-hook status --json` exits 0 even when the host is UNPAIRED, so the
    # exit code is useless as a guard -- it silently skipped pairing entirely and
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

    # Unconditionally, on every start rather than once: `install` is what moves
    # moshi's hook groups back to the TAIL of .hooks.PreToolUse, and
    # `moshi-hook status` calls the claude target `stale` whenever anything sits
    # after them. modules/claude-permissions.nix writes that file too, so the
    # order is re-established here and that module now prepends its own group to
    # keep it. Cheap, idempotent, and no config.yaml to corrupt -- unlike
    # hosts/hermes/moshi-hook.nix, which is why only that one stamps per version.
    "$moshi" install
  '';
in {
  imports = [./moshi-hook.nix ./agent-user.nix];

  # Start the user managers at boot so the daemons run without a login session.
  users.users = lib.genAttrs hookUsers (_: {linger = true;});

  systemd.user.services.moshi-hook-setup = {
    description = "Pair + install Moshi hooks";
    wantedBy = ["default.target"];
    unitConfig.ConditionUser = conditionUsers;
    # Fail loudly and retry rather than exiting 0 on a bad/missing token: an
    # unpaired daemon that reports success is the failure mode that hid the
    # broken hook wiring before. The retry also covers the ordering race -- user
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
      Environment = ["MOSHI_SOCKET_PATH=${socketUnit}"];
      Restart = "on-failure";
      RestartSec = 15;
    };
  };

  systemd.user.services.moshi-hook = {
    description = "Moshi agent hook daemon";
    unitConfig.ConditionUser = conditionUsers;
    after = ["moshi-hook-setup.service"];
    requires = ["moshi-hook-setup.service"];
    wantedBy = ["default.target"];
    serviceConfig = {
      ExecStart = "${pkgs.moshi-hook}/bin/moshi-hook serve";
      Environment = ["MOSHI_SOCKET_PATH=${socketUnit}"];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # The other half of the socket pin: hook processes are spawned by Claude Code
  # and opencode, which inherit the environment of the interactive shell they
  # were started from. Without this they resolve the socket themselves and land
  # on the /tmp fallback described above.
  environment.interactiveShellInit = ''
    export MOSHI_SOCKET_PATH="${socketShell}"
  '';
}
