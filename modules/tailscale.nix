{
  config,
  pkgs,
  ...
}: {
  services.tailscale.enable = true;

  # Tailscale requires loose reverse path filtering
  networking.firewall.checkReversePath = "loose";

  # Define the secret
  age.secrets.tailscale-auth-key.file = ../secrets/tailscale-auth-key.age;

  # Use the secret for authentication
  services.tailscale.authKeyFile = config.age.secrets.tailscale-auth-key.path;

  systemd.services.tailscaled-autoconnect = {
    # NOT `requires = ["agenix.service"]`, and not `after` either: agenix runs
    # here as a **system activation script**, not a systemd unit. A hard
    # `requires` on a unit that does not exist makes this service permanently
    # unstartable --
    #     Failed to restart tailscaled-autoconnect.service:
    #     Unit agenix.service not found.
    # -- so the dependency intended to make autoconnect more reliable was in
    # fact the thing preventing it from ever running again. (hosts/ca used
    # `wants` for step-ca, which merely degrades to a no-op when the unit is
    # missing; `requires` hard-fails.) The ordering it was reaching for is
    # already guaranteed: stage-2 runs activation, and therefore agenix,
    # before systemd starts any of this.
    #
    # `tailscaled-autoconnect` is a oneshot, so NixOS re-runs it only when its
    # generated unit file changes or on reboot -- never merely because the
    # decrypted secret changed, since ExecStart references a stable path. That
    # is exactly the reinstall case: the host boots BEFORE its secrets can be
    # re-keyed, autoconnect finds no usable auth key and gives up, and the
    # deploy that finally delivers the working key does not re-run it. The
    # host then sits at `Logged out` until someone runs `tailscale up` by hand
    # -- which is how every reinstall in this lab has gone. Bumping the nonce
    # makes the next deploy re-run the login instead.
    # Self-maintaining trigger -- deliberately `.file`, NOT `.path`:
    #
    #   .path = /run/agenix/tailscale-auth-key            (stable forever)
    #   .file = /nix/store/<hash>-tailscale-auth-key.age  (content-addressed)
    #
    # ExecStart reads `.path`, so the unit file never changes when the secret
    # is rotated and this oneshot silently keeps whatever it read at its last
    # activation. Triggering on `.file` closes that gap without anyone having
    # to remember: re-encrypting the secret changes its store path, which
    # changes this unit, which makes the next deploy re-run the login.
    #
    # Preferred over the hand-bumped `secretNonce` string used in
    # modules/attic-push.nix -- a nonce you must remember to bump fails
    # silently, which is precisely the failure this is here to prevent.
    #
    # Note age is non-deterministic (fresh ephemeral key per encryption), so
    # even a no-op re-encrypt re-runs this. Harmless here: `tailscale up` is
    # idempotent. A unit where a redundant re-run is expensive or disruptive
    # wants the manual nonce instead, so the operator picks the moment.
    restartTriggers = [config.age.secrets.tailscale-auth-key.file];
  };
}
