# Shared Caddy adjustments, imported by every host that runs Caddy.
#
# Originally just the HTTP/3 firewall hole; it now also carries the ACME
# restart nonce below, because this is the one import point common to every
# Caddy host and a per-host copy is a per-host thing to forget.
{
  config,
  lib,
  ...
}: let
  # ── ACME restart nonce ────────────────────────────────────────────────────
  # Same trick as hosts/hermes/configuration.nix's secretNonce: a string inside
  # the unit definition, so bumping it changes the unit and forces a restart on
  # the next apply.
  #
  # Why Caddy specifically needs one. Certificate state lives in
  # /var/lib/caddy, never in the unit, and CertMagic's ACME retry backoff is
  # IN-PROCESS. Once renewals wedge — the step-ca badNonce storm, where hosts
  # with many same-day vhosts fire concurrent new-order POSTs down one reused
  # HTTP/2 connection — the backoff stretches to hours and nothing retries
  # until the process restarts. Meanwhile a deploy changes nothing about the
  # unit, so switch-to-configuration leaves Caddy running and the certs keep
  # aging out.
  #
  # That is not hypothetical: on 2026-09-07 hofvarpnir.homelab.local served a
  # cert that had been expired for 3.3 days ("remaining":-285860) while Caddy
  # sat happily running, and only `systemctl restart caddy` renewed it — all
  # four of that host's certs landed within ~160s of the restart. As of
  # 2026-09-08 database.homelab.{local,internal}, pgadmin.homelab.internal and
  # unifi.homelab.local are in the same state (under 4 days left, one already
  # expired), which is what this nonce exists to clear fleet-wide.
  #
  # Bump this to force every Caddy host to restart and re-attempt ACME. Expect
  # renewal to take ~2.5 min per host after the restart, not to be instant:
  # Caddy begins renewals ~100s after startup. Do not judge it before then.
  certNonce = "2026-09-08-acme-unwedge";
in {
  # Caddy advertises h3 via alt-svc, but the NixOS firewall drops QUIC
  # packets unless UDP 443 is explicitly allowed.
  networking.firewall.allowedUDPPorts = [443];

  systemd.services.caddy = lib.mkIf config.services.caddy.enable {
    restartTriggers = [certNonce];
  };
}
