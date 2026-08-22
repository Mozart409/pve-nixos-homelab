# Aggregator: `nixosTests.x86_64-linux.<host>` in flake.nix resolves to this.
# Not wired into `checks` on purpose -- see flake.nix's `nixosTests` comment
# and AGENTS.md. Invoke explicitly: `nix build .#nixosTests.x86_64-linux.dns`
# or `just nixos-test-vm dns`.
{
  nixpkgs,
  disko,
  agenix,
  system,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  harness = import ./lib.nix {inherit pkgs disko agenix;};
in {
  dns = import ./hosts/dns.nix {inherit harness;};
  otel = import ./hosts/otel.nix {inherit harness;};
  database = import ./hosts/database.nix {inherit harness;};
}
