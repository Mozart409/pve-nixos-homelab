{...}: let
  # The `homelab` cache on hosts/cache (atticd behind Caddy).
  #
  # Attic namespaces binary-cache URLs under the cache name, so the substituter
  # URL includes it — https://cache.homelab.local alone is NOT a valid cache.
  endpoint = "https://cache.homelab.local/homelab";

  # Public half of the signing keypair atticd generated when the cache was
  # created. Re-read it at any time with:
  #
  #   just attic-info
  #
  # A wrong value here fails SILENTLY: nix rejects narinfos it cannot verify and
  # quietly falls back to building from source, so the cache appears to "work"
  # while doing nothing. If substitution seems to be ignored, check this first.
  publicKey = "homelab:REPLACE_WITH_REAL_KEY";
in {
  # nixpkgs declares `substituters` with mkAfter and `trusted-public-keys` as a
  # plain list (nixos/modules/config/nix.nix), so both MERGE with the upstream
  # defaults rather than replacing them. cache.nixos.org stays available and is
  # ordered after this one — the LAN cache is tried first, upstream is fallback.
  nix.settings = {
    substituters = [endpoint];
    trusted-public-keys = [publicKey];

    # A cache that is down must never wedge a build. Without a short timeout nix
    # waits out the default per-request budget on every path it wants to
    # substitute, which turns a powered-off cache VM into minutes of stalling
    # before it falls back. `fallback` lets it build locally when substitution
    # fails rather than aborting.
    connect-timeout = 5;
    fallback = true;
  };

  # TLS: cache.homelab.local presents a step-ca certificate, so any host using
  # this module must also import modules/step-ca-trust.nix — the nix daemon
  # verifies against the system CA bundle and will otherwise refuse the
  # substituter outright.
}
