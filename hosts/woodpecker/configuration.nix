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
    ../../modules/loki-logs.nix
  ];

  networking.hostName = "homelab-woodpecker";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.182";
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
      # The .ts.net name, NOT forgejo.homelab.local, even though every other
      # service-to-service URL in this repo uses the local name. Forgejo's
      # ROOT_URL is this .ts.net address, and Forgejo warns ("configured to be
      # served on ... you are viewing through a different URL") on any other
      # origin -- which is what the OAuth login bounce hit. Sending users to the
      # canonical URL avoids it without changing ROOT_URL, which would only move
      # the same warning onto everyone reaching Forgejo over tailscale.
      #
      # The cost: CI-to-forge traffic now depends on tailscale being up on this
      # host. MagicDNS does resolve here (unlike hermes -- see the AGENTS.md
      # pitfall), but if tailscaled is down, API calls AND pipeline clone steps
      # fail. Clone steps run inside podman containers, so they need to reach the
      # tailnet through the bridge, not just from the host.
      WOODPECKER_FORGEJO_URL = "https://homelab-forgejo.dropbear-butterfly.ts.net";

      # Forgejo sets DISABLE_REGISTRATION = true, so leaving Woodpecker open
      # would make it the weaker link: any forge account could enable pipelines
      # and, through the podman socket, run code as root on this VM.
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "amadeus";

      # sqlite. The whole DB is CI history -- cheap to rebuild, and not worth a
      # cross-host dependency on the database VM. Lives under StateDirectory
      # (/var/lib/woodpecker-server, mode 0700).
      WOODPECKER_DATABASE_DRIVER = "sqlite3";

      # The DSN params are NOT decoration -- a bare path here produced
      # wall-to-wall "database is locked" and silently killed pipelines
      # (todo/woodpecker-postgres-and-sizing.md). WAL lets readers run during a
      # write; _busy_timeout makes a blocked writer WAIT before returning
      # SQLITE_BUSY immediately; _txlock=immediate takes the write lock at
      # BEGIN rather than mid-transaction, which is what turns an unrecoverable
      # "database is locked" upgrade failure into a plain wait.
      #
      # _busy_timeout=6000 (2026-08-15): shortened from 10s to 6s at
      # amadeus's request. Note this cuts against the disk-saturation finding
      # from the same session -- sda was observed pinned near 100% util for
      # 20-30 min stretches exactly when pipelines were expiring, and a
      # shorter busy timeout gives writers less room to wait that out, not
      # more. Revert to 10000+ if "database is locked" errors reappear.
      #
      # Driver note: woodpecker 3.16 links mattn/go-sqlite3 (cgo), so these
      # `_name=value` params are correct. If a future version switches to
      # modernc.org/sqlite (pure Go), this syntax silently stops working and
      # the form becomes `?_pragma=journal_mode(WAL)&_pragma=busy_timeout(6000)`.
      # Check go.mod before trusting this line across a major bump.
      WOODPECKER_DATABASE_DATASOURCE = "/var/lib/woodpecker-server/woodpecker.sqlite?_journal_mode=WAL&_busy_timeout=6000&_txlock=immediate";

      # Upstream default is 100. A hundred pooled connections racing one sqlite
      # file is not concurrency, it is a lock convoy: sqlite serialises writes
      # anyway, so extra connections beyond a handful buy contention, not
      # throughput.
      #
      # Raised 1 -> 4 (2026-08-15) at amadeus's request. This reverses the
      # single most direct fix for the "database is locked" incident in
      # todo/woodpecker-postgres-and-sizing.md -- if wall-to-wall lock errors
      # come back, drop this to 1 again before looking anywhere else.
      WOODPECKER_DATABASE_MAX_CONNECTIONS = "4";

      # Keep per-step BUILD OUTPUT out of the database. Upstream default is
      # "database", which makes every log line a row insert -- by far the
      # highest-FREQUENCY writer here, and the one that turned lock contention
      # into dropped pipelines. Note it was never a SIZE problem: the sqlite
      # file was 1.2 MB when this was written. Frequency is what serialises.
      #
      # The store creates this directory itself (os.MkdirAll, 0700) on first
      # start, and it sits under the same StateDirectory as the DB, so
      # DynamicUser owns it and no tmpfiles rule is needed.
      #
      # One-way for EXISTING logs: pipelines already in the DB keep their rows
      # but the UI reads only the active store, so their output looks empty
      # after this switch. New pipelines are unaffected. Acceptable here for the
      # same reason the DB itself is disposable.
      WOODPECKER_LOG_STORE = "file";
      WOODPECKER_LOG_STORE_FILE_PATH = "/var/lib/woodpecker-server/logs";

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
      # 1, not 2. A workflow is not one container: a repo with a service (say a
      # postgres alongside its checks step) gets LIMIT_MEM for each of them, so
      # two workflows reserved four caps' worth on a guest that only ever had
      # room for the sum of one. Concurrency here was always notional anyway --
      # CPU_QUOTA below hands three of four cores to a single step.
      WOODPECKER_MAX_WORKFLOWS = "1";
      # 4 GB, not 1. 1 GB could not run a Rust step at all: internal-dashboard
      # unpacks the rust/llvm toolchain through `nix develop` and then links
      # `cargo test --all-targets`, and the cgroup SIGKILLed it mid-download
      # every single time -- which is why those logs always ended on a `copying
      # path` line with no error after it. A killed step also stops extending
      # its queue lease, so the server expired the workflow, exactly the
      # signature that was blamed on ballooning for #11-#25.
      #
      # This is a cap, not a reservation: a service container idles far below it
      # (postgres with 128 MB shared_buffers sits near 300 MB), so one workflow
      # peaks around 4.5 GB against the guest's 8 GB, not 8.
      WOODPECKER_BACKEND_DOCKER_LIMIT_MEM = toString (4 * 1024 * 1024 * 1024);
      # Docker semantics: mem-swap is the mem+swap TOTAL, so setting it equal to
      # LIMIT_MEM disables swap growth rather than allowing another 4 GB. Kept
      # equal deliberately -- this guest's swap lives on the zfs_pool spindles,
      # and letting a step swap there is what turned #11-#25 into fsync timeouts
      # instead of a clean, immediate OOM.
      WOODPECKER_BACKEND_DOCKER_LIMIT_MEM_SWAP = toString (4 * 1024 * 1024 * 1024);
      # 64 MB is below what postgres wants for 128 MB of shared_buffers, and the
      # suite asks for max_connections=200 on top; the service died independently
      # of the step above.
      WOODPECKER_BACKEND_DOCKER_LIMIT_SHM_SIZE = toString (256 * 1024 * 1024);
      # CFS quota against the default 100 ms period: 100000 = one full core, so
      # 300000 = three. Leaves a core for the server, Caddy and sshd, so the UI
      # stays responsive while the one workflow above compiles.
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

  # Socket activation for woodpecker-server: start the server on-demand when
  # Caddy (or direct clients) connect to port 8000. The server stays running
  # while pipelines are active; to add idle timeout, use systemd timers.
  systemd.sockets.woodpecker-server = {
    description = "Woodpecker CI Server Socket";
    listenStream = "127.0.0.1:8000";
    socketConfig.Accept = false;
  };

  # Update woodpecker-server to require socket activation.
  systemd.services.woodpecker-server = {
    requires = ["woodpecker-server.socket"];
    after = ["woodpecker-server.socket"];
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

  # Ship the woodpecker SERVER and AGENT daemon journals to the central Loki.
  #
  # Scope limit: per-step pipeline BUILD OUTPUT is not in the journal and never
  # will be -- Woodpecker stores build logs in its own sqlite DB and streams
  # them to the UI over gRPC, bypassing journald entirely. That is a Woodpecker
  # architecture fact, not a config gap. What lands in Loki is the daemon logs:
  # startup, scheduling, errors, and agent registration.
  services.loki-logs = {
    enable = true;
    units = [
      {
        unit = "woodpecker-server.service";
        job = "woodpecker-server";
      }
      {
        unit = "woodpecker-agent-podman.service";
        job = "woodpecker-agent";
      }
    ];
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
    virtualHosts."ci.homelab.local ci.homelab.internal" = {
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
    virtualHosts."http://ci.homelab.local http://ci.homelab.internal" = {
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
