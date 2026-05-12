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

    # Change sources - Forgejo webhook
    c["change_source"] = []

    # Schedulers
    c["schedulers"] = [
        schedulers.SingleBranchScheduler(
            name="all",
            change_filter=util.ChangeFilter(branch="main"),
            treeStableTimer=60,
            builderNames=["nix-build"],
        ),
        schedulers.ForceScheduler(
            name="force",
            builderNames=["nix-build"],
        ),
    ]

    # Build factory for Nix builds
    nix_factory = util.BuildFactory()
    nix_factory.addStep(steps.Git(
        repourl=util.Property("repository", default=""),
        mode="incremental",
        submodules=True,
    ))
    nix_factory.addStep(steps.ShellCommand(
        name="nix flake check",
        command=["nix", "flake", "check"],
        haltOnFailure=True,
    ))
    nix_factory.addStep(steps.ShellCommand(
        name="nix build",
        command=["nix", "build"],
        haltOnFailure=True,
    ))

    c["builders"] = [
        util.BuilderConfig(
            name="nix-build",
            workernames=["worker-1"],
            factory=nix_factory,
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

    # Database - PostgreSQL with secret from file
    c["secretsProviders"] = [
        secrets.SecretInAFile(dirname="/var/lib/buildbot/master/secrets"),
    ]

    c["db"] = {
        "db_url": "postgresql+psycopg2://buildbot:%(secret:db_password)s@192.168.2.134/buildbot",
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
  };

  # Create secrets directory for buildbot
  systemd.tmpfiles.rules = [
    "d /var/lib/buildbot/master/secrets 0700 buildbot buildbot -"
  ];

  # Write DB password to secrets file for Buildbot
  systemd.services.buildbot-master-secrets = {
    description = "Setup Buildbot secrets";
    after = ["agenix.service"];
    before = ["buildbot-master.service"];
    wantedBy = ["buildbot-master.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "buildbot";
      Group = "buildbot";
    };
    script = ''
      mkdir -p /var/lib/buildbot/master/secrets
      cp ${config.age.secrets.buildbot-db-password.path} /var/lib/buildbot/master/secrets/db_password
      chmod 600 /var/lib/buildbot/master/secrets/db_password
    '';
  };

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
          reverse_proxy localhost:8010
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
          reverse_proxy localhost:8010
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
