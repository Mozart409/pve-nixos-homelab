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
      url = "github:NousResearch/hermes-agent/pull/49431/head";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
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
    nixos-hardware,
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
        local = "192.168.2.165";
        tailscale = "192.168.2.165";
      };
      "k3s-agent-1" = {
        local = "192.168.2.156";
        tailscale = "192.168.2.156";
      };
      ca = {
        local = "192.168.2.160";
        tailscale = "homelab-ca";
      };
      fleet = {
        local = "192.168.2.164";
        tailscale = "homelab-fleet";
      };
      harbor = {
        local = "192.168.2.174";
        tailscale = "homelab-harbor";
      };
      cache = {
        local = "192.168.2.175";
        tailscale = "homelab-cache";
      };
      forgejo = {
        local = "192.168.2.178";
        tailscale = "homelab-forgejo";
      };
      buildbot-master = {
        local = "192.168.2.177";
        tailscale = "homelab-buildbot-master";
      };
      buildbot-worker-1 = {
        local = "192.168.2.179";
        tailscale = "homelab-buildbot-worker-1";
      };
      # jellyfin = {
      #   local = "192.168.2.180";
      #   tailscale = "homelab-jellyfin";
      # };
      # Raspberry Pi hosts (update IP after first boot)
      "rpi4-1" = {
        local = "192.168.2.170";
        tailscale = "homelab-rpi4-1";
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
          ./modules/nix-gc.nix
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
        # k3s-server-1 = mkHost "k3s-server-1";
        # k3s-agent-1 = mkHost "k3s-agent-1";
        ca = mkHost "ca";
        fleet = mkHost "fleet";
        harbor = mkHost "harbor";
        cache = mkHost "cache";
        forgejo = mkHost "forgejo";
        buildbot-master = mkHost "buildbot-master";
        buildbot-worker-1 = mkHost "buildbot-worker-1";
        # jellyfin = mkHost "jellyfin";
        # Raspberry Pi 4 (aarch64) - build with: nix build '.#nixosConfigurations.rpi4.config.system.build.sdImage'
        rpi4 = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            ./modules/nix-gc.nix
            ./hosts/rpi/configuration.nix
          ];
        };
        # Raspberry Pi 5 (aarch64) - build with: nix build '.#nixosConfigurations.rpi5.config.system.build.sdImage'
        rpi5 = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5
            ./modules/nix-gc.nix
            ./hosts/rpi/configuration.nix
          ];
        };
        # Named Pi hosts for Colmena deployment
        # "rpi4-1" = nixpkgs.lib.nixosSystem {
        #   system = "aarch64-linux";
        #   modules = [
        #     nixos-hardware.nixosModules.raspberry-pi-4
        #     agenix.nixosModules.default
        #     ./hosts/rpi4-1/configuration.nix
        #   ];
        # };
        hermes = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            hermes-agent.nixosModules.default
            ./hosts/hermes/configuration.nix
          ];
        };
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
            inherit nixos-hardware;
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

        hermes = {
          deployment = {
            targetHost = "192.168.2.155";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["ai" "hermes"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            hermes-agent.nixosModules.default
            ./hosts/hermes/configuration.nix
          ];
        };

        # k3s-server-1 = {
        #   deployment = {
        #     targetHost = targetHost "k3s-server-1";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["kubernetes" "k3s" "server"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/k3s-server-1/configuration.nix
        #   ];
        # };

        # k3s-agent-1 = {
        #   deployment = {
        #     targetHost = targetHost "k3s-agent-1";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["kubernetes" "k3s" "agent"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/k3s-agent-1/configuration.nix
        #   ];
        # };

        ca = {
          deployment = {
            targetHost = targetHost "ca";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["security" "ca"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/ca/configuration.nix
          ];
        };

        fleet = {
          deployment = {
            targetHost = targetHost "fleet";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["security" "fleet"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/fleet/configuration.nix
          ];
        };

        harbor = {
          deployment = {
            targetHost = targetHost "harbor";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["registry" "harbor"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/harbor/configuration.nix
          ];
        };

        cache = {
          deployment = {
            targetHost = targetHost "cache";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["cache" "s3" "nix"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/cache/configuration.nix
          ];
        };

        forgejo = {
          deployment = {
            targetHost = targetHost "forgejo";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["forgejo" "git"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/forgejo/configuration.nix
          ];
        };

        buildbot-master = {
          deployment = {
            targetHost = targetHost "buildbot-master";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["buildbot" "ci"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/buildbot-master/configuration.nix
          ];
        };

        buildbot-worker-1 = {
          deployment = {
            targetHost = targetHost "buildbot-worker-1";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["buildbot" "ci" "worker"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/buildbot-worker-1/configuration.nix
          ];
        };

        # jellyfin = {
        #   deployment = {
        #     targetHost = targetHost "jellyfin";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["media" "jellyfin"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/jellyfin/configuration.nix
        #   ];
        # };

        # Raspberry Pi 4 - builds on target (uses aarch64 binary cache)
        # "rpi4-1" = {
        #   deployment = {
        #     targetHost = targetHost "rpi4-1";
        #     targetUser = "amadeus";
        #     buildOnTarget = true;
        #     tags = ["raspberry-pi" "arm"];
        #   };
        #   nixpkgs.system = "aarch64-linux";
        #   imports = [
        #     nixos-hardware.nixosModules.raspberry-pi-4
        #     agenix.nixosModules.default
        #     ./hosts/rpi4-1/configuration.nix
        #   ];
        # };
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
          # keep-sorted start

          agenix.packages.${system}.default
          alejandra
          bacon
          # rust
          cargo
          cargo-workspaces
          claude-code
          colmena.packages.${system}.colmena
          dive
          # fmt
          dprint
          just
          keep-sorted
          # check for security issues
          kics
          lazydocker
          lefthook
          nixos-anywhere.packages.${system}.default
          #ai
          opencode
          opentofu
          podman
          podman-compose
          podman-tui
          rainfrog
          rust-analyzer
          rustc
          # k8s
          timoni
          # IaC
          tofu-ls

          # keep-sorted end
        ];
        shellHook = ''
          lefthook install
        '';
      };
    });
}
