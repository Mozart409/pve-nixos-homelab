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
  vaultPath = "${hermesHome}/workspace/vault"; # the shared Obsidian vault clone

  # ── Extra (declarative) skills ────────────────────────────────────────────
  # Custom skills shipped from this repo, exposed to Hermes read-only via the
  # `skills.external_dirs` config key (see settings below). Hermes' skill loader
  # (agent/skill_utils.py: get_all_skills_dirs) scans local ~/.hermes/skills
  # first, then every external_dirs entry, rglob-ing each for <name>/SKILL.md.
  # Pointing at this immutable store path keeps the skills reproducible and out
  # of the mutable, hub-managed ~/.hermes/skills tree. These skills are
  # instruction-only (they direct the agent's existing file/terminal tools); the
  # loader reads them host-side when building the prompt.
  #
  # NB: `./skills` is relative to THIS file, so it resolves to
  # hosts/hermes/skills/ — NOT the repo-root top-level skills/ directory. It
  # imports to the matching /nix/store path (e.g. /nix/store/…-skills) at eval.
  extraSkillsDir = ./skills; # == hosts/hermes/skills/ (relative to this file)
  # NOTE: the SSH user is "forgejo" (the built-in Forgejo SSH server's configured
  # user), NOT "git". Connecting as git@ is silently rejected by the server.
  vaultRemote = "ssh://forgejo@forgejo.homelab.local:2222/${vaultOwner}/${vaultRepoName}.git";
  gitSshCmd = "${pkgs.openssh}/bin/ssh -F ${hermesHome}/.ssh/config";

  # ── Homelab config repo (this repo) ───────────────────────────────────────
  # The agent develops changes to the NixOS homelab config on FEATURE BRANCHES
  # and, under the `local` backend (running as the hermes user), fetches + pushes
  # them to Forgejo itself with the hermes-forgejo-ssh key on ~/.ssh. `main` is
  # branch-protected on Forgejo, so the bot can never land changes directly — the
  # user reviews the branch, opens a PR, and deploys (colmena) by hand. Access
  # reuses the SAME hermes-bot Forgejo account + hermes-forgejo-ssh key as the
  # vault (same forgejo.homelab.local:2222 host the ~/.ssh/config block already
  # routes), so NO new secret is needed.
  repoOwner = "amadeus";
  repoName = "pve-nixos-homelab";
  repoPath = "${hermesHome}/workspace/${repoName}"; # the agent's repo checkout
  repoRemote = "ssh://forgejo@forgejo.homelab.local:2222/${repoOwner}/${repoName}.git";

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
      directory = ${repoPath}
  '';

  # Install ~/.ssh/config and ~/.gitconfig for the hermes user so BOTH the
  # agent's terminal git (pull-nudge) and the sync timer authenticate uniformly.
  vaultGitSetup = pkgs.writeShellScript "hermes-vault-git-setup" ''
    set -eu
    install -d -m 700 ${hermesHome}/.ssh
    install -m 600 ${vaultSshConfig} ${hermesHome}/.ssh/config
    install -m 600 ${vaultGitConfig} ${hermesHome}/.gitconfig
  '';

  # Vault checkout bootstrap: clone-if-missing + one fetch, mirroring the homelab
  # repo bootstrap below. It never commits, pulls --rebase, or pushes — the agent
  # authors commits, pulls your Obsidian edits before writing, and pushes them
  # directly (see SOUL.md + the obsidian-vault-notes skill). This oneshot only
  # guarantees the checkout EXISTS at ${vaultPath} and keeps origin fresh.
  # Idempotent and self-healing — exits 0 on a missing remote so boot retries.
  vaultBootstrap = pkgs.writeShellScript "hermes-vault-bootstrap" ''
    set -u
    export GIT_SSH_COMMAND='${gitSshCmd}'
    git=${pkgs.git}/bin/git
    if [ ! -d ${vaultPath}/.git ]; then
      mkdir -p ${hermesHome}/workspace
      if ! $git clone ${vaultRemote} ${vaultPath}; then
        echo "hermes-vault-bootstrap: clone failed (forgejo/network not ready?)" >&2
        exit 0
      fi
    fi
    cd ${vaultPath} || exit 0
    $git fetch origin --prune --quiet \
      || echo "hermes-vault-bootstrap: fetch failed" >&2
  '';

  # Bootstrap the homelab config repo checkout for the agent. Under the `local`
  # terminal backend the agent runs AS the hermes user with the Forgejo key on
  # ~/.ssh, so it fetches + pushes its own feature branches directly (see SOUL.md);
  # there is no longer a host-side pusher. This helper only guarantees the checkout
  # EXISTS at ${repoPath} and keeps origin/main fresh: clone-if-missing + a single
  # fetch. It never commits, merges, or pushes. Idempotent and self-healing — exits
  # 0 on any soft failure so the boot oneshot / timer simply retries.
  repoSync = pkgs.writeShellScript "hermes-repo-bootstrap" ''
    set -u
    export GIT_SSH_COMMAND='${gitSshCmd}'
    git=${pkgs.git}/bin/git
    mkdir -p ${repoPath}
    if [ ! -d ${repoPath}/.git ]; then
      if ! $git clone ${repoRemote} ${repoPath}; then
        echo "hermes-repo-bootstrap: clone failed (forgejo/network not ready?)" >&2
        exit 0
      fi
    fi
    cd ${repoPath} || exit 0
    $git fetch origin --prune --quiet \
      || echo "hermes-repo-bootstrap: fetch failed" >&2
  '';
in {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
    ./moshi-hook.nix
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

  # direnv + nix-direnv: `cd` into a dir with an `.envrc` (the repo already ships
  # one with `use flake`) auto-loads its flake devshell; nix-direnv caches it so
  # re-entry is instant. The module hooks the interactive zsh/bash from
  # common.nix. First use in a checkout still needs a one-time `direnv allow`.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # OpenCode Zen provider key (env-file: KEY=value lines, i.e.
  # OPENCODE_ZEN_API_KEY=sk-...). Must be an account key WITH billing, else the
  # opencode CLI only sees the free models. Consumed by hermes-agent
  # (environmentFiles below) and by the standalone `opencode` CLI wrapper in
  # environment.systemPackages, which reads the key to materialize opencode's
  # auth.json — hence owner=hermes so that wrapper (run as the hermes user) can
  # read it. systemd still reads it as root for hermes-agent regardless of owner.
  age.secrets.hermes-opencode-zen-key = {
    file = ../../secrets/hermes-opencode-zen-key.age;
    owner = "hermes";
    group = "hermes";
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

  # AgentMail API key for the agentmail MCP server (file contains
  # AGENTMAIL_API_KEY=am_...). Loaded via environmentFiles below so Hermes can
  # expand it into the agentmail MCP `x-api-key` header at runtime. Read only by
  # systemd (as root) before the agent drops privileges, so no owner needed.
  age.secrets.hermes-agentmail-key = {
    file = ../../secrets/hermes-agentmail-key.age;
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
      config.age.secrets.hermes-agentmail-key.path
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
      # Where the homelab config repo is checked out. The agent's file/terminal
      # tools (running natively as the hermes user under the `local` backend) use
      # this to locate the repo it develops on feature branches.
      HOMELAB_REPO_PATH = repoPath;
      # Agent clock timezone. Hermes resolves the time it injects into the
      # conversation via hermes_time.now(), which reads HERMES_TIMEZONE first
      # (then the config.yaml `timezone` key, then server-local). Plain `TZ` is
      # NOT consulted by that resolver, so this — not TZ — is what makes the
      # agent report Berlin instead of UTC. (The host clock / tool `date` is
      # already Berlin via modules/common.nix's time.timeZone; do NOT set
      # time.timeZone here — a second definition conflicts.)
      HERMES_TIMEZONE = "Europe/Berlin";
      # SearXNG instance backing the `web_search` tool (see settings.web below).
      # Served by Caddy on the containers host; step-ca TLS is trusted here via
      # step-ca-trust.nix. Local DNS name — MagicDNS does not resolve from hermes.
      SEARXNG_URL = "https://searxng.homelab.local";
      # SSL cert file pointing at the system CA bundle that includes the
      # Homelab step-ca root cert. httpx (used by the searxng web-search
      # provider) needs this explicitly — it fails with CERTIFICATE_VERIFY_FAILED
      # even though Python's default_verify_paths points at the same file,
      # because httpcore/httpx re-initializes the SSL context differently.
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    # Declarative configuration. The API server uses this single configured
    # provider/model (the model field Open WebUI sends is ignored for routing).
    # Switch providers by changing provider/model here and redeploying.
    settings = {
      # DeepSeek (uses DEEPSEEK_API_KEY, base_url https://api.deepseek.com/v1).
      # Alt: provider = "opencode-zen"; model = "minimax-m2.5"; (needs
      # OPENCODE_ZEN_API_KEY in hermes-opencode-zen-key.age).
      provider = "deepseek";
      # deepseek-chat is deprecated 2026-07-24 and becomes a silent alias for
      # deepseek-v4-flash; opt into the stronger v4-pro tier explicitly instead.
      model = "deepseek-v4-pro";

      # Timezone Hermes uses for the timestamps it injects into the conversation
      # (hermes_time.now(), config.yaml `timezone` key). The HERMES_TIMEZONE env
      # above takes precedence; this is the declarative belt-and-suspenders so the
      # setting survives even if the env var is ever dropped.
      timezone = "Europe/Berlin";

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

      # Extra skill directories scanned read-only in addition to the mutable
      # ~/.hermes/skills tree. Each entry is rglob-ed for <name>/SKILL.md by the
      # skill loader. Sourced from this repo (extraSkillsDir) so custom skills
      # are declarative and reproducible. The `skills` toolset must stay enabled
      # (it is, in toolsets + every platform_toolsets) for the agent to see them.
      skills.external_dirs = ["${extraSkillsDir}"];

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
      # With the podman jail gone (terminal.backend = "local", below), the floor
      # for injected shell/code is now: the systemd unit sandbox (ProtectSystem=
      # strict caps writes to stateDir/workspace, PrivateTmp, NoNewPrivileges, the
      # ReadOnlyPaths config lock + resource caps — see systemd.services below),
      # Hermes' non-bypassable "hardline" rules (rm -rf /, fork bombs, /dev/sd
      # writes, sudo -S), and the fact that hermes is its own disposable Proxmox
      # VM. Blast radius of a destructive command is bounded to the vault + agent
      # state on that VM.
      approvals.mode = "off";

      # Terminal tool backend = `local` (the module default). This governs
      # `terminal`, `execute_code`, AND the file tools (read_file/write_file/
      # search_files) — under `local` they all run as host subprocesses of the
      # agent, i.e. as the `hermes` service user, with NO container. There is thus
      # no libpod DB / runroot / pause process / persistent container to corrupt on
      # a mid-drain SIGKILL — the class of wedge that plagued the podman backend is
      # gone by construction. Confinement comes from the systemd unit sandbox
      # (ProtectSystem=strict + ReadWritePaths + ReadOnlyPaths + PrivateTmp, see
      # systemd.services.hermes-agent below), not a container. The host toolchain
      # the tools need (python3/node/nix/openssh/…) is provided via extraPackages.
      # The vault and the homelab repo are plain host paths the tools see directly
      # ($OBSIDIAN_VAULT_PATH / $HOMELAB_REPO_PATH in environment above); the agent
      # commits AND pushes with the Forgejo key on ~/.ssh (main stays branch-
      # protected on Forgejo, so it can only land feature branches via a PR).
      terminal = {
        backend = "local";
        timeout = 180;
      };

      # External memory provider: Holographic — fully local, no deps/infra.
      # Stores facts in a local SQLite FTS5 DB at $HERMES_HOME/memory_store.db.
      # NumPy (added via extraPythonPackages below) enables HRR algebra
      # (probe/reason compositional queries).
      # memory_char_limit/user_char_limit gate the BUILT-IN `memory` toolset
      # (MEMORY.md/USER.md files) — separate from the holographic fact_store
      # below, but same freeform `memory` key so they deep-merge fine. 4x the
      # module defaults (2200/1375) to give the agent more headroom.
      memory = {
        provider = "holographic";
        memory_char_limit = 8800;
        user_char_limit = 5500;
      };
      plugins.hermes-memory-store = {
        # Auto-extract facts from the conversation at session end.
        auto_extract = true;
        default_trust = 0.5;
        # Lowered from the module default (0.3) so more auto-extracted facts
        # clear the bar to persist/surface in retrieval.
        min_trust_threshold = 0.2;
      };

      # Enable the moshi-hooks plugin (installed into the agent state dir by
      # `moshi-hook install`, see ./moshi-hook.nix). Declaring it here makes the
      # registration Nix-owned so it's re-applied even after a state-dir wipe;
      # the plugin's code files still live in $HERMES_HOME/.hermes/plugins.
      plugins.enabled = ["moshi-hooks"];

      # Web search via the self-hosted SearXNG on the containers host (free,
      # no API key — reads SEARXNG_URL from environment above). Search-only:
      # SearXNG does not back `web_extract`, so that tool stays unconfigured.
      web.search_backend = "searxng";
    };

    # NumPy enables Holographic's HRR algebra (probe/reason). Matches the
    # agent's Python 3.12 env.
    extraPythonPackages = [pkgs.python312Packages.numpy];

    # Host toolchain for the `local` terminal backend. The module only puts
    # [bash coreutils git] on the service PATH; under `local` the agent's
    # terminal/execute_code tools run with that PATH (no container image), so we
    # provision what the old python-nodejs image shipped plus what the flake
    # workflow needs:
    #   - python3/nodejs  → execute_code RPC + typical shell workflows
    #   - curl/jq/grep/sed/awk/find → everyday shell tooling
    #   - nix    → `nix develop -c just fmt` + scoped `nix eval` to validate flake
    #              changes; talks to the host nix-daemon natively (no socket mount,
    #              no NIX_REMOTE — /etc/nix/nix.conf already enables flakes)
    #   - openssh → `git push` over ssh (the module PATH lacks the ssh binary);
    #              the agent now pushes its own feature branches with the Forgejo key
    extraPackages = with pkgs; [
      python3
      nodejs
      curl
      jq
      gnugrep
      gnused
      gawk
      findutils
      nix
      openssh
    ];

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
        - SAVING YOUR EDITS: after changing notes, commit AND push via the
          terminal:
          `git -C "$OBSIDIAN_VAULT_PATH" add -A && git -C "$OBSIDIAN_VAULT_PATH"
          commit -m "<concise description of the change>" && git -C
          "$OBSIDIAN_VAULT_PATH" push`. Write a meaningful message (e.g. "add eggs
          + milk to grocery list"), not a generic one. Your git is configured with
          the Forgejo key, so the push goes straight to Forgejo.
        - The user also edits the vault from Obsidian; a host timer pulls those
          changes in for you, so your view refreshes on its own. Just re-read a
          note if it looks stale.
        - Keep commits small; never run `git reset --hard` or force-push in the
          vault.

        ## Homelab Config Repo
        - This homelab's NixOS/IaC config repo is checked out at the path in
          `$HOMELAB_REPO_PATH`. Read it to understand the infrastructure and to
          make changes the user asks for. It is a Nix flake; `AGENTS.md` at its
          root documents the conventions and `just` commands.
        - NEVER commit to `main` (it is branch-protected and your commit would be
          rejected anyway). Work one FEATURE BRANCH per task, started from a fresh
          `origin/main`:
          `git -C "$HOMELAB_REPO_PATH" fetch origin && git -C "$HOMELAB_REPO_PATH" switch -c feat/<short-slug> origin/main`
        - Edit files with your file tools, then VALIDATE before committing.
          First format: `cd "$HOMELAB_REPO_PATH" && nix develop -c just fmt`.
          Then evaluate ONLY the host(s) you changed — do NOT run the full
          `just nixos-check` / `nix flake check`: it evaluates all ~16 hosts and
          gets OOM-killed (exit 137) on the host nix-daemon. A scoped eval fully
          type-checks your change instead:
          `nix eval ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"`
          (run once per edited host). A printed `/nix/store/….drv` = clean; an
          error = fix and re-run. (`nix` is on your PATH; `nix develop` provides
          `just`, `alejandra`, `tofu` from the repo's dev shell.)
        - Commit THROUGH the dev shell so the repo's pre-commit hooks (`alejandra`,
          `keep-sorted`) are on PATH and run; a bare `git commit` fails them. Do
          NOT use `--no-verify`:
          `git -C "$HOMELAB_REPO_PATH" add -A && cd "$HOMELAB_REPO_PATH" && nix develop -c git commit -m "<concise description>"`.
        - SAVING/SHARING: push your feature branch to Forgejo yourself with the
          Forgejo key your git is configured with:
          `git -C "$HOMELAB_REPO_PATH" push -u origin feat/<short-slug>`. A push to
          `main` is rejected by branch protection — that is expected. You do NOT
          open PRs, merge, or deploy: the user reviews the branch, opens the pull
          request, and deploys (`colmena`) when at the host.
        - Never run `git reset --hard`, force-push, or switch back to commit on
          `main`. If a task is unrelated to the previous one, start a brand-new
          branch from `origin/main`.

        ## Scheduled (cron) runs — delivering results
        - When you run as an UNATTENDED scheduled/cron job, there is NO chat to
          reply into: Open WebUI is pull-based and cannot receive a
          server-initiated message, so anything you "reply" is lost. You MUST
          deliver every cron result out-of-band.
        - Load and follow the `cron-result-delivery` skill. It delivers through
          two channels: (1) append the full result to `Inbox.md` in the vault,
          then commit and push it, and (2) send a short Home Assistant push via
          the `hamcp_call_service` tool (`domain="notify"`,
          `service="mobile_app_iphone_von_amadeus"`).
        - Store a memory fact reminding you to run this delivery on every
          scheduled job, so future cron runs recall it.

        ## Memory & Fact Store
        - Before answering anything about the user, their preferences, past
          decisions, or homelab history: probe/reason with `fact_store`
          FIRST. Don't answer from recall alone — check.
        - The moment you learn something durable (a preference, a decision,
          an infra fact, a recurring pattern), add or update it via
          `fact_store` immediately. Don't wait for end-of-session
          auto_extract — that's a backstop, not your primary path.
        - Prefer updating an existing fact over creating a near-duplicate.
        - `fact_store` (structured, queryable facts) and the `memory` tool
          (MEMORY.md/USER.md free text) are separate — use both.

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
      # AgentMail hosted MCP — gives the agent its own email inbox(es) to send,
      # receive, reply and manage threads. Authenticated with the x-api-key
      # header, expanded by Hermes from the agenix-loaded AGENTMAIL_API_KEY.
      agentmail = {
        url = "https://mcp.agentmail.to/mcp";
        headers."x-api-key" = "\${AGENTMAIL_API_KEY}";
      };
    };

    # Keep CLI available for debugging
    addToSystemPackages = true;
  };

  # Order hermes-agent after secrets, tailscale, and the git/vault/repo setup so
  # its native tools have DNS, the Forgejo key on ~/.ssh, and the repo checkout
  # available at startup. The module already puts [package bash coreutils git] +
  # extraPackages on the service PATH, so no path override is needed here.
  systemd.services.hermes-agent = {
    wants = ["agenix.target" "hermes-vault-bootstrap.service" "hermes-repo-sync.service"];
    after = [
      "agenix.target"
      "tailscaled.service"
      "hermes-vault-git-setup.service"
      "hermes-vault-bootstrap.service"
      "hermes-repo-sync.service"
    ];
    serviceConfig = {
      # ── Config integrity ("must stay nix") ──────────────────────────────────
      # Under the `local` backend the agent's tools run AS the hermes user, and
      # config.yaml / SOUL.md / USER.md are owned by hermes — so without this the
      # agent could rewrite its own config and system prompt at runtime. Those
      # files are (re)written on every deploy by a ROOT activation script that runs
      # OUTSIDE this unit's mount namespace, so binding them read-only here stops
      # the running agent from modifying them WITHOUT breaking the Nix merge. Nix
      # stays the sole source of truth. They are single files inside the module's
      # ReadWritePaths (stateDir, workingDirectory); systemd's most-specific-path
      # rule keeps the rest writable — the memory DB, cron jobs, sessions, logs,
      # the vault, and the repo checkout. (config.yaml lives in .hermes; the
      # documents install to workingDirectory == stateDir/workspace.)
      ReadOnlyPaths = [
        "${hermesHome}/.hermes/config.yaml"
        "${hermesHome}/workspace/SOUL.md"
        "${hermesHome}/workspace/USER.md"
      ];
      # ── Resource caps (defense-in-depth) ────────────────────────────────────
      # The tools now share this unit's cgroup. ProtectSystem=strict (module)
      # bounds writes, not CPU/pids/mem. Bound the real DoS vector — runaway
      # forks — and add a soft memory throttle. Deliberately NO hard MemoryMax:
      # pure `nix eval` (the agent's flake validation) runs client-side in THIS
      # unit, and a tight cap would OOM-kill legit scoped evals; heavy builds run
      # in the separate nix-daemon.service cgroup, unaffected by this.
      TasksMax = 512;
      LimitNPROC = 512;
      MemoryHigh = "3G";
      # The module ships TimeoutStopSec=90s, but the gateway drains up to
      # drain_timeout=180s on stop/restart; 90s SIGKILLs it mid-drain. Give the
      # drain room so shutdowns are clean. mkForce overrides the module's 90s.
      TimeoutStopSec = lib.mkForce 210;
      # NB: NoNewPrivileges reverts to the module's `true` now that the podman
      # setuid newuidmap/newgidmap requirement is gone (we no longer force it off).
    };
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

  # Vault checkout bootstrap: guarantee the vault EXISTS at boot (clone-if-missing
  # + one fetch), mirroring hermes-repo-sync below. No timer/path/auto-push — the
  # agent now pulls your Obsidian edits before writing and pushes its commits
  # directly (see the obsidian-vault-notes skill + SOUL.md).
  systemd.services.hermes-vault-bootstrap = {
    description = "Bootstrap + refresh the hermes Obsidian vault checkout";
    wantedBy = ["multi-user.target"];
    after = ["hermes-vault-git-setup.service" "network-online.target"];
    wants = ["network-online.target"];
    requires = ["hermes-vault-git-setup.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = vaultBootstrap;
    };
  };

  # ── Homelab config repo bootstrap ─────────────────────────────────────────
  # Reuses the git/ssh config installed by hermes-vault-git-setup (the
  # forgejo.homelab.local Host block + hermes-bot key apply to this repo too).
  # Under the `local` backend the agent fetches + pushes its own feature branches
  # directly with the Forgejo key (see SOUL.md), so there is NO host-side pusher.
  # This oneshot only guarantees the checkout EXISTS at ${repoPath} and keeps
  # origin/main fresh (clone-if-missing + one fetch). Runs at boot and on a slow
  # timer; never commits/merges/pushes.
  systemd.services.hermes-repo-sync = {
    description = "Bootstrap + refresh the homelab config repo checkout for the hermes agent";
    wantedBy = ["multi-user.target"];
    after = ["hermes-vault-git-setup.service" "network-online.target"];
    wants = ["network-online.target"];
    requires = ["hermes-vault-git-setup.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = repoSync;
    };
  };

  # Slow timer: keeps origin/main fresh for the agent to branch from. (The agent
  # also fetches itself before branching; this is just a background top-up.)
  systemd.timers.hermes-repo-sync = {
    description = "Periodic homelab config repo fetch";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "1min";
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
    htop
    openssh
    # Launch the interactive Hermes agent TUI as the hermes service user from a
    # hermes-readable cwd (its workspace repo). Avoids the
    # `Permission denied: '/home/amadeus/.git'` git-discovery error you hit when
    # starting it from amadeus's home (mode 0700). amadeus has passwordless sudo.
    (writeShellScriptBin "launch-hermes" ''
      exec sudo -u hermes bash -lc 'cd ~/workspace/pve-nixos-homelab && exec hermes'
    '')
    # opencode CLI. opencode only exposes the full (paid) opencode-zen catalog
    # when the key lives in its auth.json credential store — the OPENCODE_ZEN_API_KEY
    # env var only ever surfaces the 6 free models. So this wrapper materializes
    # ~/.local/share/opencode/auth.json from the agenix key on each launch, then
    # execs opencode with NO env var set (matching a normal `opencode auth login`).
    # Run as the hermes user (which owns the secret): `sudo -u hermes -i`, then
    # `opencode`. NB: the key in hermes-opencode-zen-key must be an account key
    # with billing, or only the free models appear.
    (writeShellScriptBin "opencode" ''
      envfile=${config.age.secrets.hermes-opencode-zen-key.path}
      authfile="''${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
      if [ -r "$envfile" ]; then
        set -a; . "$envfile"; set +a
        if [ -n "''${OPENCODE_ZEN_API_KEY:-}" ]; then
          mkdir -p "$(dirname "$authfile")"
          (umask 077; printf '{"opencode":{"type":"api","key":"%s"}}\n' "$OPENCODE_ZEN_API_KEY" > "$authfile")
        fi
        unset OPENCODE_ZEN_API_KEY
      fi
      exec ${pkgs.opencode}/bin/opencode "$@"
    '')
  ];
}
