# Shared nixosTest harness for hosts/<host>/configuration.nix.
#
# Deliberately does NOT go through the flake's `mkHost` (no comin, no
# home-manager/nixvim): this exercises the host's actual production config
# file, but skips the two layers that need real network infra (comin pulling
# from forgejo) or are slow/unrelated to "does this host boot and serve its
# services" (home-manager/nixvim). See AGENTS.md's "nixosTest Integration
# Tests" section for the full rationale.
{
  pkgs,
  disko,
  agenix,
}: let
  # `ens18` (the real hosts' static-IP interface) does not exist in a
  # nixosTest VM. Left alone, NixOS spends ~90s waiting on the never-appearing
  # device before giving up. Clearing the interface definition means no
  # network-addresses-ens18-style unit is even generated. Deliberately NOT
  # touching networking.useDHCP here: that flag also governs the test
  # framework's own auto-provisioned interface (conventionally eth1), which
  # must come up normally for network-online.target (a real dependency of,
  # e.g., dns's unbound.service).
  clearStaticNetworking = {lib, ...}: {
    networking.interfaces = lib.mkForce {};
    networking.defaultGateway = lib.mkForce null;
  };

  # Test-only age identity. See tests/fixtures/README.md for how it -- and the
  # fixture secrets encrypted to its public key -- were generated. This is
  # NOT a real secret: it exists solely so agenix's real decrypt pipeline can
  # legitimately succeed for the handful of secrets whose consuming PRIMARY
  # service we assert on, without touching any real key material.
  testAgeIdentity = ./fixtures/test-age-identity.txt;

  # Point agenix's decryption identity at the test-only key. Every OTHER
  # secret on the host still points at the real, production-encrypted .age
  # file under secrets/ -- those simply fail to decrypt against the test
  # identity (no matching recipient) and are left to fail softly, exactly as
  # a real reprovisioned host with no matching identity does (see AGENTS.md
  # "Reprovisioned Host -> agenix..."). Nothing downstream aborts on that
  # failure: agenix's activation script records each secret's failure
  # independently and never aborts the loop.
  useTestAgeIdentity = {lib, ...}: {
    age.identityPaths = lib.mkForce [testAgeIdentity];
  };

  # Overrides one secret's source file to a fixture encrypted to the test
  # identity's public key, so it actually decrypts inside the VM. Use only
  # for secrets whose consuming PRIMARY service is being asserted on.
  fixtureSecret = name: file: {lib, ...}: {
    age.secrets.${name}.file = lib.mkForce file;
  };
in {
  inherit clearStaticNetworking useTestAgeIdentity fixtureSecret testAgeIdentity;

  # hostPath:     path to hosts/<host>/configuration.nix
  # extraModules: per-host overrides (clearStaticNetworking, secret fixtures, ...)
  # testScript:   python testScript string (see nixosTest docs)
  mkHostTest = {
    name,
    hostPath,
    extraModules ? [],
    testScript,
    memorySize ? 1024,
  }:
    pkgs.testers.nixosTest {
      name = "homelab-${name}";
      nodes.machine = {...}: {
        imports =
          [
            disko.nixosModules.disko
            agenix.nixosModules.default
            hostPath
          ]
          ++ extraModules;
        # allowUnfree is already set on the `pkgs` instance threaded in by
        # `pkgs.testers.nixosTest` (see tests/default.nix) -- nixosTest nodes
        # use that externally-created instance, so setting `nixpkgs.config`
        # again here trips its "externally created instance" assertion.
        virtualisation.memorySize = memorySize;
      };
      inherit testScript;
    };
}
