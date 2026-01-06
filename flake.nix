{
  description = "NixOS configuration for Proxmox VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nixos-anywhere,
    disko,
    colmena,
  }: let
    system = "x86_64-linux";

    # Function to create a NixOS system configuration
    mkHost = hostname:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./hosts/${hostname}/configuration.nix
        ];
      };
  in
    {
      # NixOS configurations for each host
      nixosConfigurations = {
        ferron = mkHost "ferron";
        caddy = mkHost "caddy";
        database = mkHost "database";
      };

      # Colmena configuration for deployment
      colmena = {
        meta = {
          nixpkgs = import nixpkgs {
            inherit system;
          };
          specialArgs = {
            inherit disko;
          };
        };

        # Host definitions
        ferron = {
          deployment = {
            targetHost = "ferron.local";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["containers"];
          };
          imports = [
            disko.nixosModules.disko
            ./hosts/ferron/configuration.nix
          ];
        };

        caddy = {
          deployment = {
            targetHost = "caddy.local";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["webserver"];
          };
          imports = [
            disko.nixosModules.disko
            ./hosts/caddy/configuration.nix
          ];
        };

        database = {
          deployment = {
            targetHost = "database.local";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["database"];
          };
          imports = [
            disko.nixosModules.disko
            ./hosts/database/configuration.nix
          ];
        };
      };
    }
    // flake-utils.lib.eachDefaultSystem (system: let
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
          colmena.packages.${system}.colmena
        ];
      };
    });
}
