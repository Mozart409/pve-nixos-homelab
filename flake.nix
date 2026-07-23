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
    # MCP-server monorepo (pbs/pg/prom/loki/ha). Lives on the homelab Forgejo;
    # referenced via the local checkout until pushing from agents is unblocked.
    homelab-mcp = {
      url = "git+file:///home/amadeus/code/rust/homelab-mcp-servers";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    homelab-dashboard = {
      url = "github:Mozart409/homelab-dashboard";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mozart409-nixvim = {
      url = "github:Mozart409/mozart409-nixvim";
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
    homelab-mcp,
    hermes-agent,
    homelab-dashboard,
    home-manager,
    mozart409-nixvim,
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
      sandbox = {
        local = "192.168.2.176";
        tailscale = "homelab-sandbox";
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
      jellyfin = {
        local = "192.168.2.180";
        tailscale = "homelab-jellyfin";
      };
      zeroclaw = {
        local = "192.168.2.181";
        tailscale = "homelab-zeroclaw";
      };
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

    # Home-manager + Mozart409 nixvim for the amadeus user. Applied to every colmena
    # node via `colmenaHive.defaults`, and baked into individual nixosConfigurations
    # (used by nixos-anywhere / `just deploy`) so a reinstall keeps nixvim instead of
    # silently dropping it — mkHost does NOT include home-manager.
    homeManagerNixvim = {
      imports = [
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.amadeus = {
            imports = [mozart409-nixvim.homeModules.default];
            home.stateVersion = "25.05";
          };
        }
      ];
    };

    # Function to create a NixOS system configuration
    mkHost = hostname:
      nixpkgs.lib.nixosSystem {
        specialArgs = {inherit homelab-dashboard;};
        modules = [
          {nixpkgs.hostPlatform = system;}
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
        mcp = nixpkgs.lib.nixosSystem {
          specialArgs = {inherit homelab-dashboard homelab-mcp;};
          modules = [
            {nixpkgs.hostPlatform = system;}
            disko.nixosModules.disko
            agenix.nixosModules.default
            homelab-mcp.nixosModules.default
            ./hosts/mcp_vm/configuration.nix
          ];
        };
        # k3s-server-1 = mkHost "k3s-server-1";
        # k3s-agent-1 = mkHost "k3s-agent-1";
        ca = mkHost "ca";
        fleet = mkHost "fleet";
        harbor = mkHost "harbor";
        cache = mkHost "cache";
        forgejo = mkHost "forgejo";
        sandbox = mkHost "sandbox";
        buildbot-master = mkHost "buildbot-master";
        buildbot-worker-1 = mkHost "buildbot-worker-1";
        zeroclaw = mkHost "zeroclaw";
        # Explicit (not mkHost) so nixvim is baked in even on a nixos-anywhere
        # reinstall; mkHost omits home-manager. Mirrors colmenaHive defaults.
        jellyfin = nixpkgs.lib.nixosSystem {
          specialArgs = {inherit homelab-dashboard;};
          modules = [
            {
              nixpkgs.hostPlatform = system;
              # nixvim (via homeManagerNixvim) pulls an unfree dep; the colmenaHive
              # sets this globally, but the nixos-anywhere path needs it here too.
              nixpkgs.config.allowUnfree = true;
            }
            disko.nixosModules.disko
            agenix.nixosModules.default
            homeManagerNixvim
            ./hosts/jellyfin/configuration.nix
          ];
        };
        # Raspberry Pi 4 (aarch64) - build with: nix build '.#nixosConfigurations.rpi4.config.system.build.sdImage'
        rpi4 = nixpkgs.lib.nixosSystem {
          modules = [
            {nixpkgs.hostPlatform = "aarch64-linux";}
            nixos-hardware.nixosModules.raspberry-pi-4
            ./modules/nix-gc.nix
            ./hosts/rpi/configuration.nix
          ];
        };
        # Raspberry Pi 5 (aarch64) - build with: nix build '.#nixosConfigurations.rpi5.config.system.build.sdImage'
        rpi5 = nixpkgs.lib.nixosSystem {
          modules = [
            {nixpkgs.hostPlatform = "aarch64-linux";}
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
          modules = [
            {nixpkgs.hostPlatform = system;}
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
            inherit homelab-mcp;
            inherit hermes-agent;
            inherit homelab-dashboard;
            inherit nixos-hardware;
          };
        };

        # Applied to every node in the hive
        defaults = {
          imports = [homeManagerNixvim];
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
            homelab-mcp.nixosModules.default
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

        # cache = {
        #   deployment = {
        #     targetHost = targetHost "cache";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["cache" "s3" "nix"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/cache/configuration.nix
        #   ];
        # };

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

        sandbox = {
          deployment = {
            targetHost = targetHost "sandbox";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["sandbox" "experiment"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/sandbox/configuration.nix
          ];
        };

        # buildbot-master = {
        #   deployment = {
        #     targetHost = targetHost "buildbot-master";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["buildbot" "ci"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/buildbot-master/configuration.nix
        #   ];
        # };

        # buildbot-worker-1 = {
        #   deployment = {
        #     targetHost = targetHost "buildbot-worker-1";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["buildbot" "ci" "worker"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/buildbot-worker-1/configuration.nix
        #   ];
        # };

        jellyfin = {
          deployment = {
            targetHost = targetHost "jellyfin";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["media" "jellyfin"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/jellyfin/configuration.nix
          ];
        };

        zeroclaw = {
          deployment = {
            targetHost = targetHost "zeroclaw";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["zeroclaw" "ai"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/zeroclaw/configuration.nix
          ];
        };

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
        buildInputs = with pkgs;
          [
            # keep-sorted start

            agenix.packages.${system}.default
            alejandra
            bacon
            # rust
            cargo
            cargo-workspaces
            claude-code
            cocogitto
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
          ]
          # Linux-only in nixpkgs (no darwin client package anymore)
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.podman];
        shellHook = ''
          lefthook install
        '';
      };
    });
}
