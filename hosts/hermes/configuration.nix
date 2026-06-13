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

  # Clone-or-sync: clones on first successful run, otherwise commits local agent
  # edits, rebases on top of your Obsidian edits, and pushes. Idempotent and
  # self-healing — exits 0 on a missing remote so the timer simply retries.
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
    $git add -A
    if ! $git diff --cached --quiet; then
      $git commit -m "hermes: sync $(${pkgs.coreutils}/bin/date -Iseconds)" --quiet || true
    fi
    if ! $git pull --rebase --quiet; then
      $git rebase --abort 2>/dev/null || true
      echo "hermes-vault-sync: rebase conflict, manual resolution needed" >&2
      exit 0
    fi
    $git push --quiet || echo "hermes-vault-sync: push failed" >&2
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

      # Terminal tool backend. `local` executes shell commands directly as the
      # hardened `hermes` systemd user — NoNewPrivileges, ProtectSystem=strict,
      # and PrivateTmp from the service hardening still apply. `timeout` caps
      # each command at 180s. (Alt backends: docker/ssh/modal/daytona/
      # singularity — docker needs container.enable for full sandboxing.)
      terminal = {
        backend = "local";
        timeout = 180;
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
        - The vault is git-synced with Forgejo and also edited by the user from
          Obsidian. A background timer pulls/pushes every ~90s, so your edits
          and theirs converge automatically. If a read looks stale, you may run
          `git -C "$OBSIDIAN_VAULT_PATH" pull --rebase` via the terminal first.
        - Keep commits small; never run `git reset --hard` in the vault.

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

    # MCP Servers - Home Assistant integration.
    # Use the local DNS name (homelab DNS + step-ca TLS, trusted via
    # step-ca-trust.nix) — the Tailscale MagicDNS name does not resolve
    # from this host.
    mcpServers = {
      homeassistant = {
        url = "https://mcp.homelab.local/mcp";
        # No auth required currently
      };
    };

    # Keep CLI available for debugging
    addToSystemPackages = true;
  };

  # Ensure hermes starts after secrets are available and the vault is set up.
  # `path` puts git + ssh on the agent's PATH so its terminal tool can run the
  # pull-nudge described in SOUL.md.
  systemd.services.hermes-agent = {
    wants = ["agenix.target" "hermes-vault-sync.service"];
    after = [
      "agenix.target"
      "tailscaled.service"
      "hermes-vault-git-setup.service"
      "hermes-vault-sync.service"
    ];
    path = [pkgs.git pkgs.openssh];
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

  systemd.timers.hermes-vault-sync = {
    description = "Periodic hermes Obsidian vault sync";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "90s";
      AccuracySec = "30s";
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
