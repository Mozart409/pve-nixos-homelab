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
        database = mkHost "database";
        otel = mkHost "otel";
        dns = mkHost "dns";
        unifi = mkHost "unifi";
        minimal = mkHost "minimal";
      };

      # Colmena Hive for deployment
      colmenaHive = colmena.lib.makeHive {
        meta = {
          nixpkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          specialArgs = {
            inherit disko;
            inherit agenix;
          };
        };

        # Host definitions
        database = {
          deployment = {
            targetHost = "192.168.2.134";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["database"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/database/configuration.nix
          ];
        };

        otel = {
          deployment = {
            targetHost = "192.168.2.135";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["monitoring"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/otel/configuration.nix
          ];
        };

        dns = {
          deployment = {
            targetHost = "192.168.2.148";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["dns"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/dns/configuration.nix
          ];
        };

        unifi = {
          deployment = {
            targetHost = "192.168.2.142";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["unifi"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/unifi/configuration.nix
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
