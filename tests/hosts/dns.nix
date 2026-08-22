{harness}:
harness.mkHostTest {
  name = "dns";
  hostPath = ../../hosts/dns/configuration.nix;
  extraModules = [harness.clearStaticNetworking];
  testScript = ''
    machine.wait_for_unit("multi-user.target")

    machine.wait_for_unit("unbound.service")
    machine.wait_for_open_port(53)

    # Forward A records this host is actually configured to serve.
    machine.succeed(
        "dig @127.0.0.1 -p 53 database.homelab.local +short | grep -q '^192.168.2.134$'"
    )
    machine.succeed(
        "dig @127.0.0.1 -p 53 dns.homelab.local +short | grep -q '^192.168.2.145$'"
    )
    # homelab.internal mirror zone (Apple-client parallel zone).
    machine.succeed(
        "dig @127.0.0.1 -p 53 database.homelab.internal +short | grep -q '^192.168.2.134$'"
    )

    # Reverse (PTR) record.
    machine.succeed(
        "dig @127.0.0.1 -p 53 -x 192.168.2.134 +short | grep -q 'database.homelab.local'"
    )

    # NOT asserted on, intentionally: tailscaled-autoconnect (needs a real
    # tailscale-auth-key secret and a real control-plane connection),
    # caddy's ACME cert issuance against ca.homelab.local (no route to it in
    # the sandbox), and osquery's enrollment (unreachable fleet.homelab.local).
    # All soft-fail without affecting the assertions above.
  '';
}
