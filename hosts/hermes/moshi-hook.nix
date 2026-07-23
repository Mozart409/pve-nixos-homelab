{
  config,
  lib,
  pkgs,
  ...
}: let
  # Keep in sync with `hermesHome` in ../configuration.nix
  # (services.hermes-agent.stateDir default == HOME).
  hermesHome = "/var/lib/hermes";

  # Pair (if not already) + install, run as the hermes user with HOME pointed
  # at the REAL hermes-agent home so `install` wires the moshi-hooks plugin
  # into $HERMES_HOME/.hermes/config.yaml — which hermes-agent's
  # `plugins.enabled = ["moshi-hooks"]` (../configuration.nix) expects.
  # `status --json` guards re-pairing; `install` is documented upstream as
  # safe/idempotent to rerun ("leaves user-owned hooks alone", "survives an
  # upgrade"). Mirrors vaultBootstrap/repoSync's soft-fail convention (log +
  # exit 0) so a transient hiccup never blocks hermes-agent from starting.
  moshiPairInstall = pkgs.writeShellScript "hermes-moshi-pair-install" ''
    set -u
    moshi=${pkgs.moshi-hook}/bin/moshi-hook
    if ! "$moshi" status --json >/dev/null 2>&1; then
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
    "$moshi" install || echo "hermes-moshi-pair-install: install failed" >&2
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
