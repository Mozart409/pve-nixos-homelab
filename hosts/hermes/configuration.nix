{
  config,
  lib,
  pkgs,
  ...
}: let
  # ── Shared knowledge base (Obsidian vault) ────────────────────────────────
  # A git-synced Obsidian vault hosted in Forgejo, exposed to Hermes via the
  # bundled `note-taking/obsidian` skill (filesystem-first; uses the agent's
  # native file tools over OBSIDIAN_VAULT_PATH). You edit it via Obsidian; the
  # agent edits the local clone; a timer keeps both in sync with Forgejo.
  #
  # Adjust owner/repo to match the Forgejo repo you created and added the
  # `hermes-bot` account to as a Write collaborator (see runbook).
  vaultOwner = "amadeus";
  vaultRepoName = "obsidian-kb";
  hermesHome = "/var/lib/hermes"; # services.hermes-agent.stateDir default == $HOME
  vaultPath = "${hermesHome}/workspace/vault"; # inside the file-tool sandbox root
  # NOTE: the SSH user is "forgejo" (the built-in Forgejo SSH server's configured
  # user), NOT "git". Connecting as git@ is silently rejected by the server.
  vaultRemote = "ssh://forgejo@forgejo.homelab.local:2222/${vaultOwner}/${vaultRepoName}.git";
  gitSshCmd = "${pkgs.openssh}/bin/ssh -F ${hermesHome}/.ssh/config";

  # SSH client config: route forgejo over :2222 using the hermes-bot deploy key.
  vaultSshConfig = pkgs.writeText "hermes-vault-ssh-config" ''
    Host forgejo.homelab.local
      Port 2222
      User git
      IdentityFile ${config.age.secrets.hermes-forgejo-ssh.path}
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ${hermesHome}/.ssh/known_hosts
  '';

  # Commit identity for the bot. Rebase pulls keep history linear.
  vaultGitConfig = pkgs.writeText "hermes-vault-gitconfig" ''
    [user]
      name = hermes-bot
      email = hermes-bot@homelab.local
    [pull]
      rebase = true
    [safe]
      directory = ${vaultPath}
  '';

  # Install ~/.ssh/config and ~/.gitconfig for the hermes user so BOTH the
  # agent's terminal git (pull-nudge) and the sync timer authenticate uniformly.
  vaultGitSetup = pkgs.writeShellScript "hermes-vault-git-setup" ''
    set -eu
    install -d -m 700 ${hermesHome}/.ssh
    install -m 600 ${vaultSshConfig} ${hermesHome}/.ssh/config
    install -m 600 ${vaultGitConfig} ${hermesHome}/.gitconfig
  '';

  # Clone-or-sync: clones on first run, then PULLS your Obsidian edits and PUSHES
  # the agent's commits. It no longer commits anything itself — the agent authors
  # commits in-jail with meaningful messages (see SOUL.md); this host-side service
  # only moves them, since push/pull need the Forgejo SSH key that we deliberately
  # keep out of the agent's container. `--autostash` tucks away any uncommitted
  # agent edits across the rebase. Triggered by (a) a path unit on .git/logs/HEAD
  # when the agent commits (outbound) and (b) a slow timer (inbound). Idempotent
  # and self-healing — exits 0 on a missing remote so the trigger simply retries.
  vaultSync = pkgs.writeShellScript "hermes-vault-sync" ''
    set -u
    export GIT_SSH_COMMAND='${gitSshCmd}'
    git=${pkgs.git}/bin/git
    if [ ! -d ${vaultPath}/.git ]; then
      mkdir -p ${hermesHome}/workspace
      if ! $git clone ${vaultRemote} ${vaultPath}; then
        echo "hermes-vault-sync: clone failed (forgejo/network not ready?)" >&2
        exit 0
      fi
    fi
    cd ${vaultPath} || exit 0
    if ! $git pull --rebase --autostash --quiet; then
      $git rebase --abort 2>/dev/null || true
      echo "hermes-vault-sync: rebase conflict, manual resolution needed" >&2
      exit 0
    fi
    $git push --quiet || echo "hermes-vault-sync: push failed" >&2
  '';

  # Guard against the rootless-podman "cannot re-exec process to join the existing
  # user namespace" failure (see AGENTS.md → Common Pitfalls). A stale pause.pid that
  # references a dead pid makes EVERY podman invocation abort, breaking the
  # terminal/code/file backend until the file is removed by hand. podman auto-uses
  # /run/user/<uid> whenever it exists (linger is on) regardless of XDG_RUNTIME_DIR,
  # so check there AND the /tmp fallback. Removing a stale pidfile is safe: podman
  # recreates a fresh pause process on next use. Only removes it when its pid is NOT
  # alive, so a healthy running backend is never disturbed.
  podmanPauseGuard = pkgs.writeShellScript "hermes-podman-pause-guard" ''
    set -u
    uid=$(${pkgs.coreutils}/bin/id -u)
    for rt in "/run/user/$uid" "/tmp/storage-run-$uid"; do
      pidfile="$rt/libpod/tmp/pause.pid"
      [ -f "$pidfile" ] || continue
      pid=$(${pkgs.coreutils}/bin/cat "$pidfile" 2>/dev/null || true)
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "hermes-podman-pause-guard: removing stale $pidfile (pid='$pid' not alive)"
        rm -f "$pidfile"
      fi
    done
  '';
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
  ];

  networking.hostName = "homelab-hermes";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.155";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # OpenCode Zen provider key. To activate opencode-zen as the named provider,
  # re-key this file to contain OPENCODE_ZEN_API_KEY=... (currently holds the
  # legacy OPENAI_API_KEY/OPENAI_BASE_URL from the old custom-provider setup).
  age.secrets.hermes-opencode-zen-key = {
    file = ../../secrets/hermes-opencode-zen-key.age;
    mode = "0400";
  };

  # API server key for hermes-agent
  age.secrets.hermes-api-server-key = {
    file = ../../secrets/hermes-api-server-key.age;
    mode = "0400";
  };

  # DeepSeek provider key (file contains DEEPSEEK_API_KEY=...)
  age.secrets.hermes-deepseek-key = {
    file = ../../secrets/hermes-deepseek-key.age;
    mode = "0400";
  };

  # Axon MCP gateway bearer token (file contains AXON_GATEWAY_TOKEN=...).
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    mode = "0400";
  };

  # SSH private key for the hermes-bot Forgejo account, used to clone/push the
  # Obsidian knowledge-base vault. Owned by the hermes user (not root) because
  # ssh reads IdentityFile as the running agent/sync process. The matching
  # public key must be added to hermes-bot's Forgejo SSH keys (see runbook).
  age.secrets.hermes-forgejo-ssh = {
    file = ../../secrets/hermes-forgejo-ssh.age;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # Hermes Agent - Native mode with security hardening
  services.hermes-agent = {
    enable = true;

    # Load provider keys from secrets (files contain KEY=value format).
    # Both providers' keys are loaded so the active provider can be switched
    # via settings.provider below without touching secrets.
    environmentFiles = [
      config.age.secrets.hermes-opencode-zen-key.path
      config.age.secrets.hermes-deepseek-key.path
      config.age.secrets.hermes-api-server-key.path
      config.age.secrets.axon-gateway-env.path
    ];

    # API server config (not secrets). Named providers carry their own
    # base_url, so OPENAI_BASE_URL is no longer needed.
    environment = {
      API_SERVER_ENABLED = "true";
      # hermes API server default port; Caddy reverse_proxy targets this.
      API_SERVER_PORT = "8642";
      # Shared knowledge base for the bundled `note-taking/obsidian` skill.
      # The skill resolves notes relative to this absolute vault path.
      OBSIDIAN_VAULT_PATH = vaultPath;
      # SearXNG instance backing the `web_search` tool (see settings.web below).
      # Served by Caddy on the containers host; step-ca TLS is trusted here via
      # step-ca-trust.nix. Local DNS name — MagicDNS does not resolve from hermes.
      SEARXNG_URL = "https://searxng.homelab.local";
      # Point Hermes' container backend at rootless podman. find_docker() honors
      # this override first (before searching PATH for docker/podman), which the
      # module's restricted service PATH would otherwise hide.
      HERMES_DOCKER_BINARY = "${pkgs.podman}/bin/podman";
    };

    # Declarative configuration. The API server uses this single configured
    # provider/model (the model field Open WebUI sends is ignored for routing).
    # Switch providers by changing provider/model here and redeploying.
    settings = {
      # DeepSeek (uses DEEPSEEK_API_KEY, base_url https://api.deepseek.com/v1).
      # Alt: provider = "opencode-zen"; model = "minimax-m2.5"; (needs
      # OPENCODE_ZEN_API_KEY in hermes-opencode-zen-key.age).
      provider = "deepseek";
      model = "deepseek-chat";

      # Tool permissions. `toolsets` is the global allowlist of toolsets the
      # agent (and every gateway platform, including the API server) may use.
      # It REPLACES the built-in default, so the toolsets the Obsidian/KB
      # workflow relies on (`file`, `memory`, `skills`) are listed explicitly
      # alongside the newly granted `web` and `terminal` access.
      #   file           → read_file, write_file, patch, search_files
      #   memory         → persistent notes / user profile
      #   skills         → skills_list, skill_view, skill_manage
      #   web            → web_search, web_extract (search via SearXNG below)
      #   terminal       → terminal, process (shell + process management)
      #   browser        → browser automation (navigate/click/type/...) — note:
      #                    needs a Chromium/CDP backend to actually drive a page
      #   code_execution → execute_code (run Python that calls tools)
      #   delegation     → delegate_task (spawn subagents)
      #   session_search → search/recall past conversations
      toolsets = [
        "file"
        "memory"
        "skills"
        "web"
        "terminal"
        "browser"
        "code_execution"
        "delegation"
        "session_search"
      ];

      # Per-platform tool configuration. The top-level `toolsets` above is NOT
      # consulted per-platform: per hermes_cli/tools_config.py
      # (`_get_platform_tools`), every gateway *platform* resolves its tools ONLY
      # from `platform_toolsets.<platform>`. When a platform's key is absent it
      # falls back to that platform's built-in `default_toolset` preset
      # (`hermes-api-server` / `hermes-cli` / `hermes-cron`) — which is why Open
      # WebUI originally showed only the trimmed api-server preset. We pin each
      # platform explicitly so the tool surface is deterministic across redeploys.
      # Platform keys come from hermes_cli/platforms.py; every list entry must be
      # a CONFIGURABLE_TOOLSETS key.
      platform_toolsets = {
        # Open WebUI (chat-completions) gateway. Interactive set + `cronjob` so
        # schedules can be created straight from chat. `clarify` is omitted — the
        # chat-completions gateway can't answer an interactive clarify/approval
        # prompt (matches hermes-api-server). NB: no `todo` — SOUL.md routes all
        # todos/lists through the Obsidian vault as `- [ ]` checkboxes, so the
        # built-in ephemeral todo tool would compete with that.
        api_server = [
          "file"
          "memory"
          "skills"
          "web"
          "terminal"
          "browser"
          "code_execution"
          "delegation"
          "session_search"
          "cronjob"
        ];

        # Interactive terminal sessions (`hermes chat`). Full sane set including
        # `clarify` (a human is present to answer) and `cronjob` for managing
        # scheduled tasks. No `todo` — todos live in the Obsidian vault per SOUL.md.
        cli = [
          "file"
          "memory"
          "skills"
          "web"
          "terminal"
          "browser"
          "code_execution"
          "delegation"
          "session_search"
          "clarify"
          "cronjob"
        ];

        # Scheduled cron jobs run UNATTENDED in a fresh session, driven by the
        # gateway daemon's 60s tick (no extra service needed; jobs persist in
        # ~/.hermes/cron/jobs.json). Deliberately LEAN: the docs warn that heavy
        # toolsets (browser/delegation/moa) bloat the tool-schema prompt on every
        # LLM call of every job. `clarify` is useless unattended, and `cronjob`
        # is force-disabled inside cron runs anyway (anti-recursion guard).
        # Per-job `enabled_toolsets` on cronjob.create still overrides this.
        cron = [
          "file"
          "memory"
          "skills"
          "web"
          "terminal"
          "code_execution"
          "session_search"
        ];
      };

      # Approval mode. Default is "manual": dangerous shell/subprocess commands
      # (from `terminal` and `execute_code`) fire an interactive `approval.request`
      # and BLOCK waiting for a POST /v1/runs/{id}/approval response. The Open
      # WebUI chat-completions gateway never sends that, so those calls hang for
      # the 60s timeout and fail silently ("hitting the approval guard"). With a
      # headless API server there is no one to answer the prompt, so disable it.
      # The sandbox that replaces the approval prompt is the rootless-Podman jail
      # below (terminal.backend = "docker"): injected shell/code can only touch
      # what we bind-mount. The non-bypassable "hardline" floor in Hermes also
      # still blocks catastrophic commands (rm -rf /, fork bombs, /dev/sd writes,
      # sudo -S without SUDO_PASSWORD) regardless of this setting.
      approvals.mode = "off";

      # Terminal tool backend = rootless Podman (see Tier 2 plan).
      # This governs `terminal`, `execute_code`, AND the file tools
      # (read_file/write_file/search_files all bind to the same backend), so
      # every shell/code/file operation runs inside an ephemeral container as the
      # `hermes` user (container-root maps to host-hermes via userns). The agent
      # can therefore reach ONLY the bind-mounts below — not the agenix secrets,
      # the Forgejo deploy key in ~/.ssh, or any other host path.
      #   - find_docker() picks up podman via HERMES_DOCKER_BINARY (environment).
      #   - docker_volumes: the Obsidian vault at the SAME path so
      #     $OBSIDIAN_VAULT_PATH resolves in-container, plus the host gitconfig
      #     (read-only) so the agent's in-jail `git commit` carries the bot
      #     identity. NO ssh key is mounted: commits are local; the host-side
      #     hermes-vault-sync service does the key-bearing push/pull.
      #   - Image confirmed to ship git+python3+node (needed for execute_code
      #     RPC and in-jail commits). Network left ON so pip/curl/commit work.
      terminal = {
        backend = "docker";
        timeout = 180;
        container_persistent = true;
        docker_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        docker_volumes = [
          "${vaultPath}:${vaultPath}"
          "${hermesHome}/.gitconfig:/root/.gitconfig:ro"
        ];
        # The container does not inherit the agent's env. Set the vault path
        # inside it so the agent's `git -C "$OBSIDIAN_VAULT_PATH" commit` (per
        # SOUL.md) resolves. Same value as the host env var; the bind above puts
        # the vault at this exact path in-container.
        docker_env = {
          OBSIDIAN_VAULT_PATH = vaultPath;
        };
      };

      # External memory provider: Holographic — fully local, no deps/infra.
      # Stores facts in a local SQLite FTS5 DB at $HERMES_HOME/memory_store.db.
      # NumPy (added via extraPythonPackages below) enables HRR algebra
      # (probe/reason compositional queries).
      memory.provider = "holographic";
      plugins.hermes-memory-store = {
        # Auto-extract facts from the conversation at session end.
        auto_extract = true;
        default_trust = 0.5;
      };

      # Web search via the self-hosted SearXNG on the containers host (free,
      # no API key — reads SEARXNG_URL from environment above). Search-only:
      # SearXNG does not back `web_extract`, so that tool stays unconfigured.
      web.search_backend = "searxng";
    };

    # NumPy enables Holographic's HRR algebra (probe/reason). Matches the
    # agent's Python 3.12 env.
    extraPythonPackages = [pkgs.python312Packages.numpy];

    # System prompt and user context
    documents = {
      "SOUL.md" = ''
        # Hermes - Homelab Assistant

        You are Hermes, an AI assistant for managing a NixOS-based homelab.
        You have access to Home Assistant for smart home control.

        ## Capabilities
        - Control smart home devices via Home Assistant MCP
        - Answer questions about the homelab infrastructure
        - Help with automation tasks
        - Maintain a shared knowledge base (notes, lists, todos)

        ## Shared Knowledge Base
        - A shared Obsidian vault lives at the path in `$OBSIDIAN_VAULT_PATH`.
          Use the `obsidian` note-taking skill (file tools: read_file,
          write_file, patch, search_files) to read and edit notes, grocery
          lists, and todos there. Use `- [ ]` / `- [x]` checkboxes for tasks
          and `[[wikilinks]]` to connect notes.
        - There is no built-in todo tool; track all tasks, todos, and lists as
          checkboxes in the vault.
        - SAVING YOUR EDITS: after changing notes, commit them via the terminal:
          `git -C "$OBSIDIAN_VAULT_PATH" add -A && git -C "$OBSIDIAN_VAULT_PATH"
          commit -m "<concise description of the change>"`. Write a meaningful
          message (e.g. "add eggs + milk to grocery list"), not a generic one.
          The commit is local; a host service pushes it to Forgejo automatically
          within seconds — you do NOT push, pull, or use the SSH key yourself
          (your sandbox has neither network to Forgejo nor the key).
        - The user also edits the vault from Obsidian; a host service pulls those
          changes in for you, so your view refreshes on its own. Just re-read a
          note if it looks stale.
        - Keep commits small; never run `git reset --hard` or `git push`/`pull`
          in the vault.

        ## Guidelines
        - Be concise and helpful
        - Confirm before taking actions that affect physical devices
        - Report errors clearly
      '';
      "USER.md" = ''
        # User Context

        The user manages a Proxmox-based homelab running NixOS VMs.
        Infrastructure includes: database, monitoring (otel), DNS, UniFi controller,
        containers, and various MCP services.

        Network: 192.168.2.0/24
        Tailnet: dropbear-butterfly.ts.net
      '';
    };

    # MCP Servers - axon-gateway aggregates the homelab MCP backends behind one
    # authenticated endpoint. The header value is expanded by Hermes from the
    # agenix-loaded AXON_GATEWAY_TOKEN environment variable at runtime.
    mcpServers = {
      axon-gateway = {
        url = "https://axon.homelab.local/mcp";
        headers.Authorization = "Bearer \${AXON_GATEWAY_TOKEN}";
      };
    };

    # Keep CLI available for debugging
    addToSystemPackages = true;
  };

  # Ensure hermes starts after secrets are available and the vault is set up.
  # The module restricts the service PATH, so we extend it for the podman backend:
  #   - pkgs.podman: the rootless runtime (also pinned via HERMES_DOCKER_BINARY).
  #   - "/run/wrappers": the SETUID newuidmap/newgidmap wrappers live in
  #     /run/wrappers/bin. Rootless podman with multiple sub-UID/GID mappings
  #     shells out to these and they must be the setuid versions (NixOS puts them
  #     here). NB: the `path` option appends "/bin" to each entry, so we list the
  #     PARENT "/run/wrappers" (→ /run/wrappers/bin), NOT "/run/wrappers/bin"
  #     (which would wrongly become /run/wrappers/bin/bin). Without this, `podman
  #     version` fails: command required for rootless mode with multiple IDs:
  #     exec: "newuidmap": executable file not found in $PATH.
  systemd.services.hermes-agent = {
    wants = ["agenix.target" "hermes-vault-sync.service"];
    after = [
      "agenix.target"
      "tailscaled.service"
      "hermes-vault-git-setup.service"
      "hermes-vault-sync.service"
    ];
    path = [pkgs.git pkgs.openssh pkgs.podman "/run/wrappers"];
    # Pin rootless podman's runtime dir to the hermes user's lingering session.
    # Without this, when hermes-agent loses the startup race against the linger
    # session (i.e. /run/user/<uid> not yet present), podman falls back to a
    # /tmp/storage-run-<uid> runroot. That path later vanishes, leaving orphan
    # conmon/pasta/podman-init procs and a dead container lock, which breaks
    # execute_code with "RunRoot ... not writable" (see AGENTS.md). The uid is
    # pinned to 995 on users.users.hermes above (it is null at eval otherwise), so
    # this derivation resolves to a concrete /run/user/995.
    environment.XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.hermes.uid}";
    serviceConfig = {
      # Self-heal a stale rootless-podman pause.pid before the agent starts, so the
      # "cannot re-exec process to join the existing user namespace" failure cannot
      # recur across reboots/redeploys. Runs as the hermes service user (owns the
      # runtime dir). See podmanPauseGuard above + AGENTS.md.
      ExecStartPre = ["${podmanPauseGuard}"];
      # Rootless podman maps multiple sub-UIDs via the setuid newuidmap/newgidmap
      # helpers; NoNewPrivileges=true (set by the hermes module) makes the kernel
      # ignore their setuid bit, breaking userns setup. Relax it here — the risky
      # shell/code now runs jailed inside the podman container, so NNP on the host
      # agent process buys little once the container backend is in place.
      NoNewPrivileges = lib.mkForce false;
    };
  };

  # ── Rootless Podman (terminal/code/file-tool sandbox backend) ─────────────
  # Daemonless, no docker group (= no host-root-equivalent). The hermes-agent
  # service points its container backend here via HERMES_DOCKER_BINARY above.
  virtualisation.podman.enable = true;

  # Rootless podman needs sub-UID/GID ranges for the hermes user to map the
  # container's users (incl. its root) onto unprivileged host UIDs. The module
  # creates `hermes` as a system user; extend it with the mapping ranges.
  users.users.hermes = {
    # Pin the uid so it is known at eval time. System users get an auto-allocated
    # uid at *activation* (null during eval), which made the derived
    # `XDG_RUNTIME_DIR` below evaluate to an empty "/run/user/". 995 is the value
    # already allocated for hermes (see /run/user/995), so pinning it is a no-op at
    # runtime — no chown/migration — but makes the runtime-dir reference concrete.
    uid = 995;
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
    # Enable lingering so logind keeps a persistent user session + /run/user/<uid>
    # for the (non-login) hermes system user. This gives rootless podman a stable
    # runtime dir and a session bus, so it uses the systemd cgroup manager instead
    # of falling back to cgroupfs + an ephemeral /tmp runroot.
    linger = true;
  };

  # ── Knowledge-base vault sync ─────────────────────────────────────────────
  # Write ~/.ssh/config + ~/.gitconfig for the hermes user (one-shot, persists).
  systemd.services.hermes-vault-git-setup = {
    description = "Set up git/ssh config for the hermes knowledge-base vault";
    wantedBy = ["multi-user.target"];
    after = ["agenix.target"];
    wants = ["agenix.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "hermes";
      Group = "hermes";
      ExecStart = vaultGitSetup;
    };
  };

  # Clone-or-sync the vault. Runs once at boot and then on a timer (hybrid).
  systemd.services.hermes-vault-sync = {
    description = "Sync the hermes Obsidian vault with Forgejo (clone/pull/push)";
    wantedBy = ["multi-user.target"];
    after = ["hermes-vault-git-setup.service" "network-online.target"];
    wants = ["network-online.target"];
    requires = ["hermes-vault-git-setup.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = vaultSync;
    };
  };

  # Inbound sync: a SLOW timer pulls your Obsidian edits in. It used to run every
  # 90s and commit a timestamped "hermes: sync …" noise commit each time; now the
  # agent authors commits and this only pulls/pushes, so a relaxed cadence is
  # fine and produces no junk history.
  systemd.timers.hermes-vault-sync = {
    description = "Periodic hermes Obsidian vault pull/push";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "1min";
    };
  };

  # Outbound sync: fire the pull/push service the moment the agent commits inside
  # the jail. `.git/logs/HEAD` is appended on every commit (more reliable than
  # watching a packed ref), so PathModified gives us near-instant pushes with the
  # agent's own commit messages.
  systemd.paths.hermes-vault-sync = {
    description = "Push the hermes Obsidian vault when the agent commits";
    wantedBy = ["multi-user.target"];
    pathConfig = {
      PathModified = "${vaultPath}/.git/logs/HEAD";
      Unit = "hermes-vault-sync.service";
    };
  };

  # Caddy reverse proxy - Tailscale-only access
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-hermes.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy http://localhost:8642
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."hermes.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          reverse_proxy http://localhost:8642
        }
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy = {
    after = ["tailscaled.service"];
    wants = ["tailscaled.service"];
    serviceConfig.BindPaths = ["/run/tailscale/tailscaled.sock"];
  };

  # Strict firewall - Tailscale only, no LAN exposure
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    # Only allow SSH and node exporter on LAN (for initial setup and monitoring)
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS
      9100 # Node exporter
    ];
    # Block all other LAN access - hermes web UI only via Tailscale
  };

  environment.systemPackages = with pkgs; [
    # Minimal tools for debugging
    jq
    curl
    # Vault sync / manual conflict resolution
    git
    openssh
  ];
}
