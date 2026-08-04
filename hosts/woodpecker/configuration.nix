{
  config,
  lib,
  pkgs,
  ...
}: let
  # Public URL. Baked into the Forgejo OAuth2 redirect (${host}/authorize) and
  # into every webhook Woodpecker registers on a repo, so changing it later
  # means re-registering webhooks on every repo. No trailing slash.
  woodpeckerHost = "https://ci.homelab.local";

  # ROOTFUL podman socket, group-owned by `podman` (systemd.sockets.podman sets
  # SocketGroup = "podman"). The podman-compose prototype used the *rootless*
  # socket at /run/user/1000/podman/podman.sock with `userns_mode: keep-id`;
  # that has no systemd equivalent, so the agent joins the `podman` group
  # instead. See the static-user note on the agent unit below.
  podmanSocket = "/run/podman/podman.sock";

  # Host CA trust store. Forgejo is served with a step-ca cert, and the trust
  # store inside a pipeline step container only has the ~150 public roots -- so
  # `git clone https://forgejo.homelab.local/...` in the clone step dies with
  # `x509: certificate signed by unknown authority`. Step containers are created
  # through the docker API rather than by us, so this env var is the only way to
  # hand them the host bundle. The server itself does not need it: its unit runs
  # ProtectSystem=strict, which leaves /etc readable, and
  # modules/step-ca-trust.nix already put the homelab root in the host bundle.
  caBundle = "/etc/ssl/certs/ca-certificates.crt";
in {
  imports = [
    ../../modules/common.nix
    # NOT the shared disko-config.nix: XFS root instead of btrfs, because this
    # disk is a zvol on the host's ZFS pool and btrfs would stack a second CoW
    # (and a second compression) layer on top of it. See the module.
    ../../modules/disko-xfs.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
    ../../modules/podman.nix
  ];

  networking.hostName = "homelab-woodpecker";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.190";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Every pipeline pulls step images, and nothing reaps them. Weekly prune of
  # dangling images and stopped containers keeps CI from filling its own disk.
  virtualisation.podman.autoPrune = {
    enable = true;
    dates = "weekly";
  };

  # Woodpecker server. Version 3.16.0 in the pinned nixpkgs, which is exactly
  # the tag the podman-compose prototype ran.
  #
  # Server and agent share this VM deliberately: it keeps gRPC on loopback, so
  # no unencrypted agent traffic crosses the LAN and port 9000 stays closed.
  # (WOODPECKER_GRPC_SECURE defaults to false -- the transport is authenticated
  # by the shared secret, but it is not encrypted.)
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = woodpeckerHost;

      # Both listeners bound to loopback: Caddy terminates TLS on this same host
      # and proxies to 8000, and the only agent is local. Publishing 8000 on
      # 0.0.0.0 would expose a plaintext copy of the UI that bypasses the proxy.
      WOODPECKER_SERVER_ADDR = "127.0.0.1:8000";
      WOODPECKER_GRPC_ADDR = "127.0.0.1:9000";

      # Forgejo is the forge. Note WOODPECKER_FORGEJO_*, not the older
      # WOODPECKER_GITEA_* names -- 3.x has a dedicated Forgejo driver, and if
      # both WOODPECKER_GITEA and WOODPECKER_FORGEJO are true, Gitea silently
      # wins the driver switch.
      WOODPECKER_FORGEJO = "true";
      WOODPECKER_FORGEJO_URL = "https://forgejo.homelab.local";

      # Forgejo sets DISABLE_REGISTRATION = true, so leaving Woodpecker open
      # would make it the weaker link: any forge account could enable pipelines
      # and, through the podman socket, run code as root on this VM.
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "amadeus";

      # sqlite. The whole DB is CI history -- cheap to rebuild, and not worth a
      # cross-host dependency on the database VM. Lives under StateDirectory
      # (/var/lib/woodpecker-server, mode 0700).
      WOODPECKER_DATABASE_DRIVER = "sqlite3";
      WOODPECKER_DATABASE_DATASOURCE = "/var/lib/woodpecker-server/woodpecker.sqlite";

      # Wall-clock kill switch, in MINUTES. Upstream defaults are 60/120. MAX is
      # the real cap: a repo owner can raise a repo's timeout in the UI, but
      # never above this.
      WOODPECKER_DEFAULT_PIPELINE_TIMEOUT = "30";
      WOODPECKER_MAX_PIPELINE_TIMEOUT = "60";

      WOODPECKER_LOG_LEVEL = "info";
    };

    # WOODPECKER_AGENT_SECRET, WOODPECKER_GRPC_SECRET, WOODPECKER_FORGEJO_CLIENT,
    # WOODPECKER_FORGEJO_SECRET. GRPC_SECRET signs the JWTs handed to agents and
    # ships with the literal default "secret", so it is overridden here rather
    # than left at a publicly known value. These live in the env file rather than
    # `environment` because the latter is world-readable in the Nix store.
    environmentFile = config.age.secrets.woodpecker-server-env.path;
  };

  services.woodpecker-agents.agents.podman = {
    enable = true;

    # Becomes SupplementaryGroups on the unit, granting access to the
    # group-owned rootful podman socket.
    extraGroups = ["podman"];

    environment = {
      WOODPECKER_SERVER = "127.0.0.1:9000";

      # The "docker" backend is just the name of Woodpecker's embedded
      # Docker-API *client*. Podman's socket speaks the same API, so nothing
      # here talks to a docker daemon -- consistent with modules/podman.nix,
      # which sets dockerCompat = false on purpose. Set explicitly rather than
      # relying on auto-detect, which only probes for /var/run/docker.sock and
      # would therefore never find podman's socket on this host.
      WOODPECKER_BACKEND = "docker";
      WOODPECKER_BACKEND_DOCKER_HOST = "unix://${podmanSocket}";

      # Default is /etc/woodpecker/agent.conf, which the unit cannot write under
      # ProtectSystem=strict. If that write fails the agent still runs but
      # re-registers as a brand-new agent on every restart, accumulating orphans
      # in the server DB. Point it at the state directory instead.
      WOODPECKER_AGENT_CONFIG_FILE = "/var/lib/woodpecker-agent-podman/agent.conf";

      WOODPECKER_BACKEND_DOCKER_VOLUMES = "${caBundle}:${caBundle}:ro";

      # Per-STEP-CONTAINER resource caps. These are the only limits that
      # actually bound a runaway job: the agent asks podman to create step
      # containers over the socket, so they are podman's children, not the
      # agent unit's -- a MemoryMax= on woodpecker-agent-podman would cap the
      # agent process and nothing it spawns. Values are raw BYTES (the flags are
      # Int64), not "1g" strings.
      WOODPECKER_MAX_WORKFLOWS = "2";
      WOODPECKER_BACKEND_DOCKER_LIMIT_MEM = toString (1024 * 1024 * 1024);
      # Docker semantics: mem-swap is the mem+swap TOTAL, so setting it equal to
      # LIMIT_MEM disables swap growth rather than allowing another 1 GB.
      WOODPECKER_BACKEND_DOCKER_LIMIT_MEM_SWAP = toString (1024 * 1024 * 1024);
      WOODPECKER_BACKEND_DOCKER_LIMIT_SHM_SIZE = toString (64 * 1024 * 1024);
      # CFS quota against the default 100 ms period: 100000 = one full core, so
      # 300000 = three. Leaves a core for the server, Caddy and sshd, so the UI
      # stays responsive while two workflows compile.
      WOODPECKER_BACKEND_DOCKER_LIMIT_CPU_QUOTA = "300000";

      WOODPECKER_LOG_LEVEL = "info";
    };

    # WOODPECKER_AGENT_SECRET -- must match the server's. Note this option is a
    # bare `listOf path`, unlike the server's, which is `coercedTo path` -- a
    # single path here is a type error, so the list is required.
    environmentFile = [config.age.secrets.woodpecker-agent-env.path];
  };

  # The module defaults the agent to DynamicUser, which implies PrivateUsers=true
  # -- and inside that user namespace the `podman` supplementary group does not
  # map to the group owning the socket, so every docker-API call fails with a
  # permission error. A static system user avoids the namespace entirely.
  users.users.woodpecker-agent = {
    isSystemUser = true;
    group = "woodpecker-agent";
    description = "Woodpecker CI agent";
  };
  users.groups.woodpecker-agent = {};

  systemd.services.woodpecker-agent-podman = {
    # The socket is on-demand activated, but the agent connects to it directly
    # rather than through systemd, so it has to already be listening.
    after = ["podman.socket"];
    requires = ["podman.socket"];

    serviceConfig = {
      DynamicUser = lib.mkForce false;
      PrivateUsers = lib.mkForce false;
      User = "woodpecker-agent";
      Group = "woodpecker-agent";

      # Backs WOODPECKER_AGENT_CONFIG_FILE above.
      StateDirectory = "woodpecker-agent-podman";

      # ProtectSystem=strict mounts the hierarchy read-only, and connecting to a
      # unix socket needs write permission on the socket inode. Without this the
      # agent cannot reach podman at all.
      ReadWritePaths = ["/run/podman"];
    };
  };

  age.secrets.woodpecker-server-env = {
    file = ../../secrets/woodpecker-server-env.age;
    mode = "0400";
  };

  age.secrets.woodpecker-agent-env = {
    file = ../../secrets/woodpecker-agent-env.age;
    mode = "0400";
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
    virtualHosts."homelab-woodpecker.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy 127.0.0.1:8000 {
            flush_interval -1
          }
        }
      '';
    };

    # Local network hostname with step-ca certificate. This is WOODPECKER_HOST,
    # so it is effectively permanent -- it is baked into the OAuth redirect and
    # every registered webhook.
    virtualHosts."ci.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          reverse_proxy 127.0.0.1:8000 {
            # Pipeline logs stream over a single long-lived response. Without
            # this Caddy buffers them and the live log view looks frozen.
            flush_interval -1
          }
        }
      '';
    };

    # Redirect plain HTTP to HTTPS for the local hostname.
    virtualHosts."http://ci.homelab.local" = {
      extraConfig = ''
        redir https://{host}{uri} permanent
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  # Firewall configuration. Note 8000 (UI) and 9000 (gRPC) are deliberately
  # absent: both listeners are bound to loopback and reached via Caddy or, for
  # gRPC, only by the agent on this same host.
  networking.firewall = {
    enable = true;
    # `podman+` covers every netavark bridge. Woodpecker creates a fresh network
    # per pipeline (podman1, podman2, …), and step containers resolve names via
    # aardvark-dns listening on that bridge's gateway address — which is INPUT to
    # this host. Without the bridge trusted the firewall drops those queries and
    # the clone step dies resolving forgejo.homelab.local. Same fix as harbor
    # (`podman1`) and development (`podman+`).
    trustedInterfaces = ["tailscale0" "podman+"];
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP (Caddy redirect to HTTPS)
      443 # HTTPS (Caddy)
      9100 # Node exporter
    ];
  };

  environment.systemPackages = with pkgs; [
    git
  ];
}
