{
  description = "NixOS configuration for Proxmox VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    agenix,
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
          agenix.nixosModules.default
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

      # Colmena Hive for deployment
      colmenaHive = colmena.lib.makeHive {
        meta = {
          nixpkgs = import nixpkgs {
            inherit system;
          };
          specialArgs = {
            inherit disko;
            inherit agenix;
          };
        };

        # Host definitions
        ferron = {
          deployment = {
            targetHost = "192.168.2.132";
            targetUser = "amadeus";
            buildOnTarget = true;
            tags = ["containers"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/ferron/configuration.nix
          ];
        };

        caddy = {
          deployment = {
            targetHost = "192.168.2.131";
            targetUser = "amadeus";
            buildOnTarget = true;
            tags = ["webserver"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/caddy/configuration.nix
          ];
        };

        database = {
          deployment = {
            targetHost = "192.168.2.133";
            targetUser = "amadeus";
            buildOnTarget = true;
            tags = ["database"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
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
          agenix.packages.${system}.default
        ];
      };
    });
}
