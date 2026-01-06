{
  description = "Development shell with Podman and Podman Compose";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nixos-anywhere,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          podman
          podman-compose
          podman-tui
          dive
          lazydocker
          # check for security issues
          kics
          just
          # rust
          cargo
          cargo-workspaces
          rust-analyzer
          rustc
          bacon
          # fmt
          dprint

          # IaC
          tofu-ls
          opentofu
          nixos-anywhere.packages.${system}.default
        ];
      };
    });
}
