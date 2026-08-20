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

        # unbound auto-configures both "local." (RFC 6762, mDNS) and
        # "internal." (RFC 9476) as reserved special-use TLDs and answers
        # them NXDOMAIN internally by default. The homelab runs parallel
        # `*.homelab.local` and `*.homelab.internal` zones (the latter for
        # Apple/mDNS clients that force *.local off-DNS, see
        # hosts/dns/configuration.nix), so both need overriding or this stub
        # breaks the moment any host's `networking.nameservers` points at it.
        #
        # Getting this right needs BOTH pieces below -- confirmed by actually
        # running the built config through `unbound -d -c ...` and `dig`
        # against it, not just a green build (Nix happily writes a config
        # that never starts, and a config that starts but silently NXDOMAINs
        # everything under these TLDs):
        #   1. `local-zone: <tld> transparent` here, to suppress unbound's
        #      built-in default handling for the reserved TLD (its presence,
        #      not really its type, is what matters -- omit it and unbound's
        #      instant built-in NXDOMAIN wins over even a specific
        #      forward-zone).
        #   2. A forward-zone specifically for that TLD (below), not just the
        #      catch-all "." one -- without it, "transparent" falls through
        #      to real iterative resolution via the internet root servers
        #      (which genuinely NXDOMAINs, since "local"/"internal" aren't
        #      real gTLDs) instead of consulting any configured forward-zone.
        # This MUST live inside `server`, not as a sibling of it -- placed at
        # the `settings` top level it renders as a bare `local-zone:` line
        # positioned after `forward-zone:`'s content with nothing to re-open
        # a clause, which unbound's line-based (indentation-insensitive)
        # parser reads as still belonging to `forward-zone:` and rejects
        # with a syntax error (caught with `unbound-checkconf` against the
        # actual generated /etc/unbound/unbound.conf).
        local-zone = ["local. transparent" "internal. transparent"];
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = ["192.168.2.145" "192.168.2.1"];
        }
        {
          name = "local.";
          forward-addr = ["192.168.2.145" "192.168.2.1"];
        }
        {
          name = "internal.";
          forward-addr = ["192.168.2.145" "192.168.2.1"];
        }
        # Tailscale's tailscaled normally self-inserts 100.100.100.100 (its
        # own MagicDNS resolver, always reachable locally over tailscale0)
        # into /etc/resolv.conf at runtime, on top of whatever
        # `networking.nameservers` says. Overriding `networking.nameservers`
        # below regenerates resolv.conf on activation and can race/clobber
        # that dynamic entry -- confirmed live: `git push` (over the Tailscale
        # SSH remote) failed to resolve its *.ts.net host right after this
        # module's first deploy, while `dig @100.100.100.100` for the same
        # name answered fine (Tailscale itself was healthy; only the default
        # resolution path was broken). Forwarding "ts.net." explicitly here
        # makes this host's own MagicDNS resolution correct by construction
        # instead of depending on tailscaled's self-healing race.
        {
          name = "ts.net.";
          forward-addr = ["100.100.100.100"];
        }
      ];
    };
  };

  # Override modules/common.nix's `lib.mkDefault` -- resolve through the local
  # cache, not the `dns` host directly.
  networking.nameservers = ["127.0.0.1"];
}
