{
  config,
  lib,
  pkgs,
  ...
}:
# Every host queries the `dns` host's unbound directly over the network
# (modules/common.nix: `networking.nameservers`) with zero local caching --
# plain glibc resolver, no systemd-resolved/nscd. A brief hiccup on the `dns`
# host or the network path to it therefore fails every in-flight lookup on
# every host at once. This hit hard on 2026-08-20: a comin-poll burst caused
# a ~13 minute run of DNS/forgejo pull failures across six hosts simultaneously
# (see docs/deployment-status-2026-08-18.md).
#
# Fix: a tiny local unbound stub-resolver on every OTHER host, forwarding to
# the `dns` host (then the LAN gateway as fallback). It still queries fresh on
# every lookup, but `serve-expired` means a slow/unreachable upstream serves
# the last-known-good cached answer instead of failing the client outright,
# and `cache-min-ttl` floors retention at 30 minutes regardless of the
# record's own TTL.
#
# Skipped on the `dns` host itself -- it already runs the full authoritative
# unbound instance (hosts/dns/configuration.nix); a second instance here would
# fight it over the same service/port.
lib.mkIf (config.networking.hostName != "homelab-dns") {
  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = ["127.0.0.1"];
        port = 53;
        access-control = ["127.0.0.0/8 allow"];
        do-ip6 = false;

        # 30 min floor on cache retention, regardless of the record's own TTL.
        cache-min-ttl = 1800;
        # Serve a stale cached answer instead of failing when upstream is slow
        # or unreachable.
        serve-expired = true;
        serve-expired-ttl = 1800;
        # ms: fall back to the stale cache if upstream takes longer than this.
        serve-expired-client-timeout = 1800;
        # Refresh popular entries just before they expire.
        prefetch = true;
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = ["192.168.2.145" "192.168.2.1"];
        }
      ];
    };
  };

  # Override modules/common.nix's `lib.mkDefault` -- resolve through the local
  # cache, not the `dns` host directly.
  networking.nameservers = ["127.0.0.1"];
}
