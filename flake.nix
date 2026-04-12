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
    hamcp = {
      url = "github:mozart409/hamcp-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
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
    hamcp,
    hermes-agent,
  }: let
    system = "x86_64-linux";

    # Set DEPLOY_NET=tailscale to use Tailscale hosts, defaults to local IPs
    deployNet = builtins.getEnv "DEPLOY_NET";

    hostAddrs = {
      database = {
        local = "192.168.2.134";
        tailscale = "homelab-database";
      };
      otel = {
        local = "192.168.2.135";
        tailscale = "homelab-otel";
      };
      dns = {
        local = "192.168.2.145";
        tailscale = "homelab-dns";
      };
      unifi = {
        local = "192.168.2.142";
        tailscale = "homelab-unifi";
      };
      containers = {
        local = "192.168.2.149";
        tailscale = "homelab-containers";
      };
      mcp = {
        local = "192.168.2.152";
        tailscale = "homelab-mcp";
      };
      "k3s-server-1" = {
        local = "192.168.2.157";
        tailscale = "192.168.2.157";
      };
      "k3s-agent-1" = {
        local = "192.168.2.156";
        tailscale = "192.168.2.156";
      };
    };

    targetHost = name:
      if deployNet == "tailscale"
      then hostAddrs.${name}.tailscale
      else hostAddrs.${name}.local;

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
        containers = mkHost "containers";
        minimal = mkHost "minimal";
        k3s-server-1 = mkHost "k3s-server-1";
        k3s-agent-1 = mkHost "k3s-agent-1";
        # hermes = nixpkgs.lib.nixosSystem {
        #   inherit system;
        #   modules = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     hermes-agent.nixosModules.default
        #     ./hosts/hermes/configuration.nix
        #   ];
        # };
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
            inherit hamcp;
            inherit hermes-agent;
          };
        };

        # Host definitions
        database = {
          deployment = {
            targetHost = targetHost "database";
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
            targetHost = targetHost "otel";
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
            targetHost = targetHost "dns";
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
            targetHost = targetHost "unifi";
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
        containers = {
          deployment = {
            targetHost = targetHost "containers";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["containers"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/containers/configuration.nix
          ];
        };

        mcp = {
          deployment = {
            targetHost = targetHost "mcp";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["mcp"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            hamcp.nixosModules.default
            ./hosts/mcp_vm/configuration.nix
          ];
        };

        # hermes = {
        #   deployment = {
        #     targetHost = "192.168.2.155";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["ai" "hermes"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     hermes-agent.nixosModules.default
        #     ./hosts/hermes/configuration.nix
        #   ];
        # };

        k3s-server-1 = {
          deployment = {
            targetHost = targetHost "k3s-server-1";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["kubernetes" "k3s" "server"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/k3s-server-1/configuration.nix
          ];
        };

        k3s-agent-1 = {
          deployment = {
            targetHost = targetHost "k3s-agent-1";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["kubernetes" "k3s" "agent"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/k3s-agent-1/configuration.nix
          ];
        };
        # END
      };
    }
    // flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
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
          rainfrog
          # fmt
          dprint

          #ai
          opencode
          claude-code

          # k8s
          timoni

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
