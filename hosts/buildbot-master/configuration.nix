{
  config,
  lib,
  pkgs,
  ...
}: let
  # Buildbot master configuration file
  masterCfgFile = pkgs.writeText "master.cfg" ''
    from buildbot.plugins import *
    from buildbot.process.properties import Interpolate
    import os

    c = BuildmasterConfig = {}

    # Worker configuration - read password at runtime
    worker_password_file = "/run/agenix/buildbot-worker-password"
    with open(worker_password_file) as f:
        worker_password = f.read().strip()

    c["workers"] = [
        worker.Worker("worker-1", worker_password),
    ]

    c["protocols"] = {"pb": {"port": 9989}}

    # Change sources - poll Forgejo for new commits
    c["change_source"] = [
        changes.GitPoller(
            repourl="https://homelab-forgejo.dropbear-butterfly.ts.net/amadeus/pve-nixos-homelab.git",
            branches=True,  # poll all branches (covers PR branches too)
            pollInterval=120,  # check every 2 minutes
            project="pve-nixos-homelab",
        ),
    ]

    # Schedulers
    c["schedulers"] = [
        # Main branch pushes
        schedulers.SingleBranchScheduler(
            name="main-push",
            change_filter=util.ChangeFilter(branch="refs/heads/main"),
            treeStableTimer=60,
            builderNames=["nix-flake-check"],
        ),
        # All other branches (PR branches)
        schedulers.AnyBranchScheduler(
            name="branches",
            change_filter=util.ChangeFilter(branch_fn=lambda b: b != "refs/heads/main"),
            treeStableTimer=30,
            builderNames=["nix-flake-check"],
        ),
        # Manual trigger
        schedulers.ForceScheduler(
            name="force",
            builderNames=["nix-flake-check"],
        ),
    ]

    # Build factory for nix flake check
    nix_check_factory = util.BuildFactory()
    nix_check_factory.addStep(steps.Git(
        repourl="https://homelab-forgejo.dropbear-butterfly.ts.net/amadeus/pve-nixos-homelab.git",
        mode="full",
        method="clobber",
        submodules=True,
        haltOnFailure=True,
    ))
    nix_check_factory.addStep(steps.ShellCommand(
        name="nix flake check",
        command=["nix", "flake", "check", "--show-trace", "--print-build-logs"],
        haltOnFailure=True,
        timeout=3600,
    ))

    c["builders"] = [
        util.BuilderConfig(
            name="nix-flake-check",
            workernames=["worker-1"],
            factory=nix_check_factory,
        ),
    ]

    # Web interface
    c["www"] = {
        "port": 8010,
        "plugins": {
            "waterfall_view": {},
            "console_view": {},
            "grid_view": {},
        },
    }

    # Database - PostgreSQL (read password at runtime)
    db_password_file = "/run/agenix/buildbot-db-password"
    with open(db_password_file) as f:
        db_password = f.read().strip()

    from urllib.parse import quote_plus
    c["db"] = {
        "db_url": f"postgresql+psycopg2://buildbot:{quote_plus(db_password)}@192.168.2.134/buildbot",
    }

    # Project identity
    c["title"] = "Homelab CI"
    c["titleURL"] = "https://homelab-buildbot-master.dropbear-butterfly.ts.net/"
    c["buildbotURL"] = "https://homelab-buildbot-master.dropbear-butterfly.ts.net/"
  '';
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
  ];

  networking.hostName = "homelab-buildbot-master";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.177";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Buildbot secrets
  age.secrets.buildbot-worker-password = {
    file = ../../secrets/buildbot-worker-password.age;
    owner = "buildbot";
    group = "buildbot";
  };

  age.secrets.buildbot-db-password = {
    file = ../../secrets/buildbot-db-password.age;
    owner = "buildbot";
    group = "buildbot";
  };

  # Buildbot Master
  services.buildbot-master = {
    enable = true;
    masterCfg = masterCfgFile;
    buildbotDir = "/var/lib/buildbot/master";
    packages = with pkgs; [
      git
      nix
    ];
    pythonPackages = python3Packages:
      with python3Packages; [
        psycopg2
      ];
  };

  # Create buildbot directories with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/buildbot 0750 buildbot buildbot -"
    "d /var/lib/buildbot/master 0750 buildbot buildbot -"
  ];

  # Prometheus exporters
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-buildbot-master.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy 127.0.0.1:8010
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."buildbot-master.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          reverse_proxy 127.0.0.1:8010
        }
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      8010 # Buildbot web UI
      9989 # Buildbot worker protocol
      9100 # Node exporter
    ];
  };

  environment.systemPackages = with pkgs; [
    git
  ];
}
