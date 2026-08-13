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
    # MCP-server monorepo (pbs/pg/prom/loki/ha). Lives on the homelab Forgejo.
    # Fetched over HTTPS (repo is public + step-ca trusted everywhere) so no SSH
    # key is needed by CI or build hosts; the old git+ssh ts.net URL needed a
    # shared forgejo key and MagicDNS, which is unreliable between homelab VMs.
    homelab-mcp = {
      url = "git+https://forgejo.homelab.local/amadeus/homelab-mcp-servers.git";
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
    herdr = {
      url = "github:ogulcancelik/herdr/v0.7.5";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixos-unstable (26.11) dropped x86_64-darwin; this pins the last
    # darwin-capable channel for the Intel Mac devShell only.
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
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
    herdr,
    nixpkgs-darwin,
  }: let
    system = "x86_64-linux";

    # Set DEPLOY_NET=tailscale to use Tailscale hosts, defaults to local IPs
    deployNet = builtins.getEnv "DEPLOY_NET";

    # Deploy targets. `local` holds the *.homelab.local name (A records in
    # hosts/dns/configuration.nix) rather than the raw IP, so re-addressing a
    # host is a one-line change there. Both paths resolve these names: on the LAN
    # via unbound on the dns host, and over the tailnet via the tailnet-wide
    # split-DNS route homelab.local -> 192.168.2.145 (reached through the subnet
    # route the dns host advertises).
    hostAddrs = {
      database = {
        local = "database.homelab.local";
        tailscale = "homelab-database";
      };
      otel = {
        local = "otel.homelab.local";
        tailscale = "homelab-otel";
      };
      # Stays an IP on purpose. This host *is* the resolver every other entry
      # above depends on, so naming it dns.homelab.local would mean you cannot
      # deploy the fix for a broken unbound without a working unbound.
      dns = {
        local = "192.168.2.145";
        tailscale = "homelab-dns";
      };
      unifi = {
        local = "unifi.homelab.local";
        tailscale = "homelab-unifi";
      };
      containers = {
        local = "containers.homelab.local";
        tailscale = "homelab-containers";
      };
      mcp = {
        local = "mcp.homelab.local";
        tailscale = "homelab-mcp";
      };
      "k3s-server-1" = {
        local = "k3s-server-1.homelab.local";
        tailscale = "k3s-server-1.homelab.local";
      };
      "k3s-agent-1" = {
        local = "k3s-agent-1.homelab.local";
        tailscale = "k3s-agent-1.homelab.local";
      };
      ca = {
        local = "ca.homelab.local";
        tailscale = "homelab-ca";
      };
      fleet = {
        local = "fleet.homelab.local";
        tailscale = "homelab-fleet";
      };
      harbor = {
        local = "harbor.homelab.local";
        tailscale = "homelab-harbor";
      };
      cache = {
        local = "cache.homelab.local";
        tailscale = "homelab-cache";
      };
      development = {
        local = "development.homelab.local";
        tailscale = "homelab-development";
      };
      forgejo = {
        local = "forgejo.homelab.local";
        tailscale = "homelab-forgejo";
      };
      jellyfin = {
        local = "jellyfin.homelab.local";
        tailscale = "homelab-jellyfin";
      };
      zeroclaw = {
        local = "zeroclaw.homelab.local";
        tailscale = "homelab-zeroclaw";
      };
      woodpecker = {
        local = "woodpecker.homelab.local";
        tailscale = "homelab-woodpecker";
      };
      # Raspberry Pi hosts (update IP after first boot). Left as an IP because
      # there is no rpi4-1.homelab.local record to point at -- the node is still
      # commented out of both nixosConfigurations and colmenaHive below, and the
      # address is a placeholder until it takes a lease. Add the A/PTR pair in
      # hosts/dns/configuration.nix when the host is actually brought up.
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
          {
            nixpkgs.hostPlatform = system;
            # colmenaHive.meta.nixpkgs sets this globally for colmena builds;
            # plain nixosSystem entries need it too so `nix build
            # .#nixosConfigurations.<host>...` works standalone.
            nixpkgs.config.allowUnfree = true;
          }
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
        # Bootable installer ISO. Explicit (not mkHost) because mkHost injects
        # disko, which a live medium has no use for. Build with:
        # just iso-build
        iso = nixpkgs.lib.nixosSystem {
          modules = [
            {nixpkgs.hostPlatform = system;}
            ./hosts/iso/configuration.nix
          ];
        };
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
        # Explicit (not mkHost) so `herdr` can be passed via specialArgs, and so
        # nixvim is baked in even on a nixos-anywhere reinstall. Mirrors
        # colmenaHive defaults — see the jellyfin entry below.
        development = nixpkgs.lib.nixosSystem {
          specialArgs = {inherit herdr;};
          modules = [
            {
              nixpkgs.hostPlatform = system;
              # claude-code is unfree; the colmenaHive sets this globally, but
              # plain nixosSystem entries need it too so `nix build
              # .#nixosConfigurations.development...` works standalone.
              nixpkgs.config.allowUnfree = true;
            }
            disko.nixosModules.disko
            agenix.nixosModules.default
            homeManagerNixvim
            ./hosts/development/configuration.nix
          ];
        };
        buildbot-master = mkHost "buildbot-master";
        buildbot-worker-1 = mkHost "buildbot-worker-1";
        zeroclaw = mkHost "zeroclaw";
        woodpecker = mkHost "woodpecker";
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
            inherit herdr;
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
            # Not routed through hostAddrs/targetHost like the other nodes --
            # hermes has no hostAddrs entry, so DEPLOY_NET=tailscale does not
            # switch it over.
            targetHost = "hermes.homelab.local";
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

        woodpecker = {
          deployment = {
            targetHost = targetHost "woodpecker";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["ci" "woodpecker"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/woodpecker/configuration.nix
          ];
        };

        development = {
          deployment = {
            targetHost = targetHost "development";
            targetUser = "amadeus";
            buildOnTarget = false;
            tags = ["development" "experiment"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/development/configuration.nix
          ];
        };

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

        # zeroclaw = {
        #   deployment = {
        #     targetHost = targetHost "zeroclaw";
        #     targetUser = "amadeus";
        #     buildOnTarget = false;
        #     tags = ["zeroclaw" "ai"];
        #   };
        #   imports = [
        #     disko.nixosModules.disko
        #     agenix.nixosModules.default
        #     ./hosts/zeroclaw/configuration.nix
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
    // flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"] (system: let
      # nixos-unstable (26.11) dropped x86_64-darwin, so the Intel Mac devShell
      # imports nixpkgs-darwin (26.05, the last darwin-capable channel) instead.
      darwinLegacy = system == "x86_64-darwin";
      pkgs =
        import (
          if darwinLegacy
          then nixpkgs-darwin
          else nixpkgs
        ) {
          inherit system;
          config.allowUnfree = true;
        };
      # These track nixos-unstable, which no longer evaluates for x86_64-darwin;
      # on that system fall back to the 26.05-darwin channel packages (agenix
      # was removed from nixpkgs, so build it from the pinned source).
      agenixPkg =
        if darwinLegacy
        then pkgs.callPackage "${agenix}/pkgs/agenix.nix" {}
        else agenix.packages.${system}.default;
      colmenaPkg =
        if darwinLegacy
        then pkgs.colmena
        else colmena.packages.${system}.colmena;
      nixosAnywherePkg =
        if darwinLegacy
        then pkgs.nixos-anywhere
        else nixos-anywhere.packages.${system}.default;
    in {
      # Woodpecker CI image pulled by .woodpecker/static.yml and .woodpecker/iac.yml.
      # Linux-only (dockerTools needs a Linux build); build and push to Harbor with
      # `just ci-image-push` after creating a public `ci` project. The nix pipeline
      # (.woodpecker/nix.yml) uses `nixos/nix` instead, not this image.
      packages = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
        ci-image = let
          # kics (nixpkgs) ships WITHOUT its query library, and kics bails
          # out ("unable to find queries") instead of downloading them. Vendor
          # the queries from the matching release tag into the image so scans
          # work offline; the pipeline passes -q /opt/kics-queries.
          kicsQueries = pkgs.fetchFromGitHub {
            owner = "Checkmarx";
            repo = "kics";
            # v2.1.19, pinned by commit SHA (not tag). The hash is the
            # UNPACKED-tree hash (what fetchFromGitHub/fetchzip verifies), NOT
            # the raw tarball bytes -- GitHub regenerates tarballs with fresh
            # gzip metadata, so nix-prefetch-url's file hash drifts on every
            # download. Get it with `nix-prefetch-git --rev <sha>`.
            rev = "4f798f77f478efb722548dbd50812be00a6dbf6c";
            sha256 = "0qs3hmj08q5dzm01ys71r30n4phk8ivf81x5vxkc6h3pmsm7n03j";
          };
        in
          pkgs.dockerTools.buildImage {
            name = "pve-nixos-homelab-ci";
            tag = "latest";
            copyToRoot = pkgs.buildEnv {
              name = "ci-tools";
              paths = with pkgs; [
                alejandra
                bash
                cacert
                cocogitto
                coreutils
                curl
                git
                gnugrep
                gnused
                kics
                keep-sorted
                opentofu
                dockerTools.binSh
                dockerTools.fakeNss
                dockerTools.usrBinEnv
                (pkgs.runCommand "kics-queries" {} ''
                  mkdir -p $out/opt/kics-queries
                  cp -r ${kicsQueries}/assets/queries/. $out/opt/kics-queries/
                '')
              ];
              # Link /bin so every tool lands on PATH, /etc so cacert's bundle
              # lands at /etc/ssl/certs (tofu/kics hit public registries), and
              # /opt for the vendored kics queries. The woodpecker agent
              # additionally bind-mounts the host step-ca bundle over
              # /etc/ssl/certs/ca-certificates.crt for LAN hosts.
              pathsToLink = ["/bin" "/etc" "/usr" "/opt"];
            };
            config = {
              Cmd = ["/bin/sh" "-c" "true"];
              Env = [
                "PATH=/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "HOME=/root"
                "USER=root"
              ];
            };
          };
      };
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs;
          [
            # keep-sorted start

            agenixPkg
            alejandra
            bacon
            # rust
            cargo
            cargo-workspaces
            claude-code
            cocogitto
            colmenaPkg
            dive
            # fmt
            dprint
            just
            keep-sorted
            # check for security issues
            kics
            lazydocker
            lefthook
            nixosAnywherePkg
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
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.podman]
          # darwin-only in nixpkgs
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [pkgs.git];
        shellHook = ''
          lefthook install
        '';
      };
    });
}
