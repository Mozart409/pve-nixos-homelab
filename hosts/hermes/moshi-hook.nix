{
  config,
  lib,
  pkgs,
  ...
}: let
  # Keep in sync with `hermesHome` in ../configuration.nix
  # (services.hermes-agent.stateDir default == HOME).
  hermesHome = "/var/lib/hermes";

  # `moshi-hook install` REWRITES $HERMES_HOME/.hermes/config.yaml in place to
  # register the plugin, and it is NOT safe to rerun against a file another
  # writer has reformatted — despite upstream calling it idempotent.
  #
  # Two writers touch that file, with INCOMPATIBLE list styles:
  #   - the hermes-agent module's activation-time `hermes-config-merge` re-dumps
  #     the WHOLE file via PyYAML, emitting sequences at 2-space indent
  #     (`  - moshi-hooks`);
  #   - `moshi-hook install` writes/matches its own 4-space style
  #     (`    - moshi-hooks`).
  # Neither recognizes the other's form, so running `install` on a file the merge
  # just normalized makes it INSERT a duplicate 4-space item directly under
  # `enabled:`, above the existing 2-space one. Two sequence items at different
  # depths is unparseable YAML, and hermes fails OPEN on a parse error
  # (gateway/run.py:_load_gateway_config -> empty dict), silently discarding every
  # override — `model` included. The DeepSeek API then gets model="" and returns
  # HTTP 400 "supported API model names are deepseek-v4-pro or deepseek-v4-flash,
  # but you passed .". See AGENTS.md §6 for the full incident.
  #
  # Fix: run `install` only ONCE per moshi-hook version. The stamp lives in the
  # agent state dir, so a state-dir wipe re-runs it, and a version bump re-runs it
  # (the `--target hermes` hook files may change between releases). Steady state
  # therefore has a SINGLE writer — the Nix merge — and the registration stays
  # declarative via `plugins.enabled = ["moshi-hooks"]` in ../configuration.nix.
  # `hermes-config-check` (../configuration.nix) repairs + validates the file after
  # this unit, covering the one boot after a version bump where `install` does run.
  # That unit is `RemainAfterExit`, so it needed `partOf = moshi-hook-setup` to be
  # dragged along when a deploy restarts THIS unit mid-boot; without it the repair
  # simply never ran and the corruption surfaced on the next deploy's activation.
  installStamp = "${hermesHome}/.hermes/.moshi-hook-installed-${pkgs.moshi-hook.version}";

  # Pair (if not already) + install, run as the hermes user with HOME pointed
  # at the REAL hermes-agent home so `install` wires the moshi-hooks plugin
  # into $HERMES_HOME/.hermes/config.yaml. `status --json` guards re-pairing.
  # Mirrors vaultBootstrap/repoSync's soft-fail convention (log + exit 0) so a
  # transient hiccup never blocks hermes-agent from starting.
  moshiPairInstall = pkgs.writeShellScript "hermes-moshi-pair-install" ''
    set -u
    moshi=${pkgs.moshi-hook}/bin/moshi-hook
    # `status --json` exits 0 even when the host is UNPAIRED, so guarding on its
    # exit code silently skipped pairing forever — hermes was found running
    # unpaired, i.e. no notification ever reached the phone. Test the `paired`
    # field itself. (Same bug was fixed in modules/moshi-hook-user.nix.)
    if ! "$moshi" status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -e '.paired == true' >/dev/null 2>&1; then
      token="$(cat ${config.age.secrets.moshi-device-id.path} 2>/dev/null)"
      if [ -z "$token" ]; then
        echo "hermes-moshi-pair-install: moshi-device-id secret unreadable, skipping" >&2
        exit 0
      fi
      if ! "$moshi" pair --token "$token"; then
        echo "hermes-moshi-pair-install: pair failed (network/token?)" >&2
        exit 0
      fi
    fi
    if [ -e ${installStamp} ]; then
      echo "hermes-moshi-pair-install: hooks already installed for v${pkgs.moshi-hook.version}; skipping (would rewrite config.yaml)"
      exit 0
    fi
    if "$moshi" install; then
      touch ${installStamp}
    else
      echo "hermes-moshi-pair-install: install failed" >&2
    fi
  '';
in {
  systemd.services.moshi-hook-setup = {
    description = "Pair + install Moshi hooks for the hermes agent";
    after = ["agenix.target"];
    wants = ["agenix.target"];
    environment.HOME = hermesHome;
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = moshiPairInstall;
    };
  };

  # No firewall change needed: the gateway is loopback-only and the phone app
  # reaches it over the existing mosh/SSH-over-Tailscale session.
  systemd.services.moshi-hook = {
    description = "Moshi agent hook daemon";
    after = ["network-online.target" "moshi-hook-setup.service"];
    wants = ["network-online.target"];
    requires = ["moshi-hook-setup.service"];
    wantedBy = ["multi-user.target"];
    environment.HOME = hermesHome;
    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      ExecStart = "${pkgs.moshi-hook}/bin/moshi-hook serve";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
