{
  config,
  lib,
  pkgs,
  ...
}: {
  # Attic push token for the `homelab` cache (plain JWT, NOT KEY=value — it is
  # passed as a positional argument to `attic login`, not sourced as env).
  # Pulling needs no credential (modules/attic-cache.nix, public cache); this
  # is only what lets a host UPLOAD what it builds. Shared admin token minted
  # once via `just attic-init` — every comin host reuses the same secret file,
  # so giving a new host push access is a secrets.nix recipient change plus
  # `just reencrypt`, not a new token.
  age.secrets.attic-push-token = {
    file = ../secrets/attic-push-token.age;
    owner = "amadeus";
    mode = "0400";
  };

  # `attic login` writes ~/.config/attic/config.toml, which is mutable state
  # the attic client has no declarative option for — so a reinstall would
  # silently lose the ability to push until someone re-ran the command by
  # hand. This oneshot re-applies it on every activation, making the token
  # the only thing that has to survive.
  systemd.services.attic-login = {
    description = "Register the homelab attic cache for the amadeus user";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "amadeus";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.attic-client}/bin/attic login homelab \
        https://cache.homelab.local/homelab \
        "$(cat ${config.age.secrets.attic-push-token.path})"
    '';
  };

  # Push this host's closure after every successful activation — comin's
  # `nixos-rebuild switch` included, since activation scripts run regardless
  # of what triggered the switch. Every comin host ends up pushing every
  # generation it builds, so the next host that shares a derivation (nixpkgs,
  # a common module, a flake input) substitutes it from the LAN cache instead
  # of building it from source or pulling it over WAN from cache.nixos.org.
  #
  # Runs detached (`--no-block`) so a slow or unreachable cache never delays
  # or fails the activation that triggered it; failures are visible in
  # `systemctl status attic-push-system` / the unit's journal, not in comin's
  # own deploy result.
  systemd.services.attic-push-system = {
    description = "Push the current system closure to the homelab attic cache";
    after = ["attic-login.service" "network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "amadeus";
      ExecStart = "${pkgs.attic-client}/bin/attic push homelab /run/current-system";
    };
  };

  system.activationScripts.attic-push-trigger = lib.stringAfter ["users" "groups"] ''
    ${pkgs.systemd}/bin/systemctl start --no-block attic-push-system.service || true
  '';

  environment.systemPackages = [pkgs.attic-client];
}
