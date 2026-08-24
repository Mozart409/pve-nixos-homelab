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
    comin = {
      url = "github:nlewo/comin";
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
    # PINNED — do not float this input back to the branch head without testing.
    # hermes-agent 0.20.1 (rev d0021673, pulled in by `chore(deps): upgrade
    # flake`) ships a `hermes_cli/plugins.py` that imports a module missing from
    # the built env, so the gateway crash-loops on startup:
    #   File ".../hermes_cli/plugins.py", line 62, in <module>
    #       from registration_lifecycle import replacement_coordinator
    #   ModuleNotFoundError: No module named 'registration_lifecycle'
    # It dies in `_install_plugin_message_injector`, i.e. the plugin-manager
    # path, so `plugins.enabled = ["moshi-hooks"]` is enough to trip it. Nothing
    # about the moshi/config.yaml layer is at fault — hermes-config-check passes
    # and `model` resolves. 98105f31 is the last rev that starts. Unpin once
    # upstream ships the missing module.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/98105f31f46d3de58a8f69a2a439cee3f7a5e389";
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
    # Upstream org renamed ogulcancelik -> herdrdev (NixOS/nixpkgs mirrors this).
    herdr = {
      url = "github:herdrdev/herdr/v0.8.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # crush (charmbracelet/crush) and other coding-agent CLIs, curated by
    # numtide. crush IS packaged in nixpkgs too, but its FSL-1.1-MIT license
    # makes nixpkgs mark it `meta.unfree = true` -- Hydra never builds unfree
    # packages, so cache.nixos.org and our own attic cache (modules/attic-cache.nix)
    # both 404 on it and every host would compile the Go source itself. This
    # flake publishes its own binary cache (see its `nixConfig` -- niks3 at
    # cache.numtide.com) that DOES have it prebuilt, wired into
    # hosts/development below via `nix.settings.substituters`.
    nix-ai-tools = {
      url = "github:numtide/nix-ai-tools";
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
    comin,
    homelab-mcp,
    hermes-agent,
    homelab-dashboard,
    home-manager,
    mozart409-nixvim,
    nixos-hardware,
    herdr,
    nix-ai-tools,
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

    # Home-manager + Mozart409 nixvim + tmux for the amadeus user. Applied to every
    # colmena node via `colmenaHive.defaults`, and baked into every
    # nixosConfiguration via mkHost so comin (which builds nixosConfigurations)
    # and colmena (which builds the hive) produce the SAME closure — without this
    # parity the two tools would flip-flop nixvim/tmux on every poll/apply.
    homeManagerNixvim = {
      imports = [
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.amadeus = {
            imports = [
              mozart409-nixvim.homeModules.default
              ./modules/tmux.nix
            ];
            home.stateVersion = "25.05";
          };
        }
      ];
    };

    # Comin module parameterized by the FLAKE ATTRIBUTE name (comin derives
    # nixosConfigurations.<hostname> from it; networking.hostName is
    # "homelab-<name>" everywhere and would not match).
    cominFor = hostname: import ./modules/comin.nix {inherit comin hostname;};

    # Function to create a NixOS system configuration. Every mkHost host gets
    # home-manager/nixvim (hive parity, see above) and comin. Hosts that must
    # NOT (bootstrap/installer images like `minimal` and `iso`) are explicit
    # nixosSystem entries instead.
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
          homeManagerNixvim
          (cominFor hostname)
          ./modules/container-registries.nix
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
        # Bootstrap image for nixos-anywhere (`just deploy-minimal`). Explicit
        # (not mkHost) because it must NOT get home-manager/nixvim (slows the
        # install) or comin (a bootstrap host should not self-deploy).
        minimal = nixpkgs.lib.nixosSystem {
          specialArgs = {inherit homelab-dashboard;};
          modules = [
            {
              nixpkgs.hostPlatform = system;
              nixpkgs.config.allowUnfree = true;
            }
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/minimal/configuration.nix
          ];
        };
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
            {
              nixpkgs.hostPlatform = system;
              # nixvim (via homeManagerNixvim) pulls an unfree dep; the
              # colmenaHive sets this globally, plain nixosSystem needs it too.
              nixpkgs.config.allowUnfree = true;
            }
            disko.nixosModules.disko
            agenix.nixosModules.default
            homelab-mcp.nixosModules.default
            homeManagerNixvim
            (cominFor "mcp")
            ./hosts/mcp_vm/configuration.nix
          ];
        };
        ca = mkHost "ca";
        fleet = mkHost "fleet";
        harbor = mkHost "harbor";
        cache = mkHost "cache";
        forgejo = mkHost "forgejo";
        # Explicit (not mkHost) so `herdr`/`nix-ai-tools` can be passed via specialArgs.
        development = nixpkgs.lib.nixosSystem {
          specialArgs = {inherit herdr nix-ai-tools;};
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
            (cominFor "development")
            ./hosts/development/configuration.nix
          ];
        };
        zeroclaw = mkHost "zeroclaw";
        woodpecker = mkHost "woodpecker";
        # Explicit (not mkHost) because of the disko-jellyfin multi-disk layout
        # history; module set otherwise mirrors mkHost.
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
            (cominFor "jellyfin")
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
            {
              nixpkgs.hostPlatform = system;
              # nixvim (via homeManagerNixvim) pulls an unfree dep; the
              # colmenaHive sets this globally, plain nixosSystem needs it too.
              nixpkgs.config.allowUnfree = true;
            }
            disko.nixosModules.disko
            agenix.nixosModules.default
            hermes-agent.nixosModules.default
            homeManagerNixvim
            (cominFor "hermes")
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
            inherit nix-ai-tools;
          };
        };

        # Applied to every node in the hive
        defaults = {
          imports = [homeManagerNixvim ./modules/container-registries.nix];
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
            (cominFor "database")
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
            (cominFor "otel")
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
            (cominFor "dns")
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
            (cominFor "unifi")
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
            (cominFor "containers")
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
            (cominFor "mcp")
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
            (cominFor "hermes")
            ./hosts/hermes/configuration.nix
          ];
        };

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
            (cominFor "ca")
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
            (cominFor "fleet")
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
            (cominFor "harbor")
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
            (cominFor "cache")
            ./hosts/cache/configuration.nix
          ];
        };

        forgejo = {
          deployment = {
            targetHost = targetHost "forgejo";
            # forgejo.homelab.local also serves Forgejo's Git SSH endpoint on
            # port 2222; Colmena must use the VM's OpenSSH service instead.
            targetPort = 22;
            targetUser = "amadeus";
            sshOptions = [
              "-i"
              "/home/amadeus/.ssh/id_colmena_deploy"
              "-o"
              "IdentitiesOnly=yes"
            ];
            buildOnTarget = false;
            tags = ["forgejo" "git"];
          };
          imports = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            (cominFor "forgejo")
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
            (cominFor "woodpecker")
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
            (cominFor "development")
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
            (cominFor "jellyfin")
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

      # Opt-in QEMU integration tests (boot + primary-service availability).
      # NOT under `checks` -- nix flake check/just check/just nixos-check all
      # build `checks.*`, and this repo already works around nix-daemon OOM
      # from full evaluation (AGENTS.md §3/§7); several real VM boots is
      # heavier still. Invoke explicitly: `just nixos-test-vm <host>`.
      nixosTests.${system} = import ./tests {inherit nixpkgs disko agenix system;};
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
            # buildEnv only materializes the linked paths, so the image has no
            # /tmp and no /root. tofu init unpacks provider zips through
            # os.CreateTemp and kics writes scan scratch files -- both die with
            # "no such file or directory" without /tmp -- and HOME below points
            # at /root.
            extraCommands = ''
              mkdir -p tmp root
              chmod 1777 tmp
            '';
            config = {
              Cmd = ["/bin/sh" "-c" "true"];
              Env = [
                "PATH=/bin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"
                # ca-certificates.crt, NOT cacert's ca-bundle.crt: the woodpecker
                # agent bind-mounts the host step-ca bundle over exactly that
                # path (hosts/woodpecker/configuration.nix). Pointing at the
                # other file in the same directory silently bypasses the mount
                # and leaves Go tools with the public roots only, so any
                # *.homelab.local TLS fails with "certificate signed by unknown
                # authority".
                "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
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

            # IaC

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
            pwgen
            rainfrog
            rust-analyzer
            rustc
            # k8s
            timoni
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
