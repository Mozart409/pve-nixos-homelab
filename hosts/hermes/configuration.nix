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

  # ── Extra (declarative) skills ────────────────────────────────────────────
  # Custom skills shipped from this repo, exposed to Hermes read-only via the
  # `skills.external_dirs` config key (see settings below). Hermes' skill loader
  # (agent/skill_utils.py: get_all_skills_dirs) scans local ~/.hermes/skills
  # first, then every external_dirs entry, rglob-ing each for <name>/SKILL.md.
  # Pointing at this immutable store path keeps the skills reproducible and out
  # of the mutable, hub-managed ~/.hermes/skills tree. These skills are
  # instruction-only (they direct the agent's existing file/terminal tools), so
  # they do NOT need to be bind-mounted into the podman sandbox — the loader
  # reads them host-side when building the prompt.
  extraSkillsDir = ./skills;
  # NOTE: the SSH user is "forgejo" (the built-in Forgejo SSH server's configured
  # user), NOT "git". Connecting as git@ is silently rejected by the server.
  vaultRemote = "ssh://forgejo@forgejo.homelab.local:2222/${vaultOwner}/${vaultRepoName}.git";
  gitSshCmd = "${pkgs.openssh}/bin/ssh -F ${hermesHome}/.ssh/config";

  # ── Homelab config repo (this repo) ───────────────────────────────────────
  # The agent develops changes to the NixOS homelab config on FEATURE BRANCHES
  # inside its podman sandbox; a host-side service (hermes-repo-sync) pushes those
  # branches to Forgejo. `main` is branch-protected on Forgejo, so the bot can
  # never land changes directly — the user reviews the branch, opens a PR, and
  # deploys (colmena) by hand. Access reuses the SAME hermes-bot Forgejo account
  # + hermes-forgejo-ssh key as the vault (same forgejo.homelab.local:2222 host
  # the ~/.ssh/config block already routes), so NO new secret is needed. The key
  # stays host-side only — it is never mounted into the sandbox.
  repoOwner = "amadeus";
  repoName = "pve-nixos-homelab";
  repoPath = "${hermesHome}/workspace/${repoName}"; # inside the file-tool sandbox root
  repoRemote = "ssh://forgejo@forgejo.homelab.local:2222/${repoOwner}/${repoName}.git";

  # Put `nix` on PATH inside the sandbox even for LOGIN shells. Hermes runs
  # terminal commands through a login shell, and the nikolaik image's
  # /etc/profile *hard-resets* PATH to a fixed default — discarding the
  # docker_env.PATH below (which only survives in non-login shells). /etc/profile
  # then sources /etc/profile.d/*.sh AFTER that reset (via run-parts), so dropping
  # this file there re-adds the host nix bin (and every nix CLI tool). Verified
  # in-image: the addition survives `bash -lc`. Filename must match run-parts'
  # `^[a-zA-Z0-9_][a-zA-Z0-9._-]*\.sh$` — `hermes-nix.sh` (the mount target) does.
  nixProfileScript = pkgs.writeText "hermes-nix-profile.sh" ''
    export PATH="$PATH:${pkgs.nix}/bin"
  '';

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

  # Clone-or-push for the homelab config repo. Push-ONLY (the inverse emphasis of
  # the vault): it never commits, never merges, and NEVER pushes main — the agent
  # authors commits in-jail on feature branches (see SOUL.md) and the user opens
  # the PR + deploys. This host-side service moves the agent's branch out using
  # the Forgejo SSH key we keep out of the container. Idempotent and self-healing:
  #   - clone-if-empty (into a pre-created empty dir so the agent's bind-mount
  #     target always exists; a failed clone just leaves the empty dir + retries),
  #   - `git fetch` keeps origin/main fresh for the agent to branch from,
  #   - push only when HEAD is a non-main branch with commits ahead of origin/main.
  # Triggered by (a) a path unit on .git/logs/HEAD when the agent commits and
  # (b) a slow timer (fetch + retry). Exits 0 on any soft failure so triggers retry.
  repoSync = pkgs.writeShellScript "hermes-repo-sync" ''
    set -u
    export GIT_SSH_COMMAND='${gitSshCmd}'
    git=${pkgs.git}/bin/git
    mkdir -p ${repoPath}
    if [ ! -d ${repoPath}/.git ]; then
      if ! $git clone ${repoRemote} ${repoPath}; then
        echo "hermes-repo-sync: clone failed (forgejo/network not ready?)" >&2
        exit 0
      fi
    fi
    cd ${repoPath} || exit 0
    if ! $git fetch origin --prune --quiet; then
      echo "hermes-repo-sync: fetch failed" >&2
      exit 0
    fi
    branch=$($git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    case "$branch" in
      main | master | HEAD)
        # Never push the protected/default branch; just keep origin fresh.
        exit 0
        ;;
    esac
    ahead=$($git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] 2>/dev/null || exit 0
    $git push -u origin "$branch" --quiet \
      || echo "hermes-repo-sync: push of '$branch' failed" >&2
  '';

  # ── Deterministic rootless-podman runroot ────────────────────────────────
  # The recurring "execute_code → Docker version failed" wedge is NOT (only) a
  # stale pause.pid — its real cause is an UNDETERMINED runroot. Hermes invokes
  # podman with XDG_RUNTIME_DIR stripped, so podman computes the runroot from the
  # environment on each fresh init: it uses /run/user/995 when that exists, else
  # falls back to /tmp/storage-run-995. Whichever it sees FIRST gets baked into
  # the libpod DB (db.sql) and from then on podman *enforces* it, overriding the
  # other and aborting with "database configuration mismatch" / an unwritable
  # /tmp runroot. `podman system migrate` only papers over it until the next init
  # re-bakes a divergent path. The fix is to PIN the runroot so it is identical
  # no matter how (or how early) podman is invoked.
  #
  # We pin it to /run/hermes-podman, created deterministically by systemd's
  # RuntimeDirectory= for the hermes-agent unit (owned by the service user, mode
  # 0700, on tmpfs, materialised BEFORE ExecStartPre, cleaned per boot) — exactly
  # what a runroot should be, with no dependence on logind's lingering session.
  podmanRunRoot = "/run/hermes-podman";
  podmanStorageConf = pkgs.writeText "hermes-storage.conf" ''
    [storage]
    driver = "overlay"
    graphroot = "${hermesHome}/.local/share/containers/storage"
    runroot = "${podmanRunRoot}"
  '';
  # Force the cgroupfs cgroup manager. podman defaults to the *systemd* manager,
  # where crun creates the container's cgroup scope by calling StartTransientUnit
  # on the hermes user's systemd over the session D-Bus (/run/user/995/bus). But
  # Hermes invokes podman with XDG_RUNTIME_DIR stripped, so crun can't find that
  # bus, falls back to the SYSTEM bus as the unprivileged hermes uid, and is
  # denied — surfacing as `podman run` exit code 126 ("crun: sd-bus call:
  # Permission denied") and Hermes' "couldn't start the sandbox container".
  # cgroupfs makes crun manage cgroups directly under the unit's delegated
  # subtree (see Delegate=true on the service) with no D-Bus call, so containers
  # start headlessly regardless of the session bus. Verified: `podman run
  # --cgroup-manager=cgroupfs ...` launches the sandbox image and returns output.
  #
  # tmp_dir = pin the libpod runtime tmp dir (and with it the OCI runtime's
  # exit-files directory) onto the same systemd-managed tmpfs. This is the LAST
  # logind dependency: podman derives the OCI runtime exit-files dir from
  # Engine.TmpDir, which for rootless defaults to /run/user/<uid>/libpod/tmp —
  # NOT from XDG_RUNTIME_DIR (pinning XDG moved the runroot but NOT this). When
  # user@<uid> is down, /run/user/<uid> is a stale root-owned dir hermes can't
  # write, so crun init fails with "creating OCI runtime exit files directory:
  # mkdir /run/user/<uid>: permission denied" — surfaced (misleadingly) as
  # `podman version` → exit 125 'default OCI runtime "crun" not found'. Pinning
  # tmp_dir here puts the exit dir under /run/hermes-podman, so the sandbox no
  # longer needs the user session at all (this is what makes linger removable).
  podmanContainersConf = pkgs.writeText "hermes-containers.conf" ''
    [engine]
    cgroup_manager = "cgroupfs"
    tmp_dir = "${podmanRunRoot}/libpod-tmp"
  '';
  # Install ~/.config/containers/{storage,containers}.conf for the hermes user.
  # podman reads these regardless of the (sanitised) invocation environment, so
  # both the runroot and the cgroup manager are deterministic for the service,
  # the sync timer, and any manual debugging.
  podmanStorageSetup = pkgs.writeShellScript "hermes-podman-storage-setup" ''
    set -eu
    install -d -m 700 ${hermesHome}/.config/containers
    install -m 644 ${podmanStorageConf} ${hermesHome}/.config/containers/storage.conf
    install -m 644 ${podmanContainersConf} ${hermesHome}/.config/containers/containers.conf
  '';

  # Guard against rootless-podman failures that wedge the terminal/code/file backend
  # until cleaned by hand (see AGENTS.md → Common Pitfalls). Runs at ExecStartPre as
  # the hermes user, BEFORE the agent starts — so there is never a legitimate live
  # container at this point, which makes the cleanup below unambiguously safe.
  #
  # Two leftovers from a crashed/previous instance can wedge podman:
  #   1. Orphan conmon/pasta/podman-init helpers still holding the rootless user
  #      namespace + storage flocks → new podman aborts with "cannot re-exec process
  #      to join the existing user namespace" (and surfaces as execute_code's "Docker
  #      version failed"). Killing them releases the locks/namespace. This is the
  #      actual recurring root cause — a stale pause.pid alone did not explain it.
  #   2. A stale pause.pid pointing at a dead pid → every podman invocation aborts.
  #      Removed only when its pid is NOT alive. podman auto-uses /run/user/<uid>
  #      when it exists (linger is on) AND the /tmp fallback, so check both.
  podmanPauseGuard = pkgs.writeShellScript "hermes-podman-pause-guard" ''
    set -u
    uid=$(${pkgs.coreutils}/bin/id -u)
    # (0) Ensure the pinned runroot's libpod tmp subtree exists. systemd recreates a
    #     BARE ${podmanRunRoot} on each start (RuntimeDirectoryPreserve defaults to
    #     "no"), but podman — with XDG_RUNTIME_DIR pinned here — needs
    #     $XDG/libpod/tmp/ to pre-exist to set up its per-user PAUSE PROCESS. It does
    #     NOT reliably create that subtree itself, failing with "unable to create a
    #     new pause process: ... open ${podmanRunRoot}/libpod/tmp/pause.pid: no such
    #     file or directory". The pause process is per-user (not per-container), so
    #     container_persistent=false does not touch this path. Verified on-host:
    #     pre-creating the subtree fixes the wedge; without it every podman run exits
    #     125 a minute into a stable instance.
    ${pkgs.coreutils}/bin/mkdir -p "${podmanRunRoot}/libpod/tmp"
    # (1) Reap orphan helpers left by a prior instance (the agent is not running yet,
    #     so any of these owned by this user are stale and safe to kill).
    for proc in conmon pasta podman-init catatonit; do
      ${pkgs.procps}/bin/pkill -9 -u "$uid" -f "$proc" 2>/dev/null || true
    done
    # (2) Remove a stale pause.pid (only when its pid is no longer alive). Cover
    #     the pinned runroot plus the legacy auto-selected locations, in case an
    #     older boot left one behind before the runroot was pinned.
    for rt in "${podmanRunRoot}" "/run/user/$uid" "/tmp/storage-run-$uid"; do
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
        # Two INDEPENDENT knobs (verified in tools/environments/docker.py):
        #   • container_persistent → persistent_filesystem: only controls whether
        #     /workspace + /root are bind-mounted (persisted) or tmpfs (ephemeral).
        #     It does NOT govern the container lifecycle. We use tmpfs (false); the
        #     vault is bind-mounted explicitly via docker_volumes regardless.
        #   • docker_persist_across_processes (default TRUE) → the real one: when
        #     true the agent keeps ONE `sleep infinity` container and REUSES it
        #     across Hermes processes/restarts by label, doing `podman start` on the
        #     stale one — which fails `exit 125` after a mid-drain SIGKILL corrupts
        #     it (the recurring "execute_code → Docker version failed" wedge). This
        #     is the persistent container the plan set out to remove. Setting it
        #     false makes each agent process create its own container and stop+rm it
        #     on exit (docker.py:1236) — no cross-restart reuse, so the corruption
        #     vector is gone. Within a process the container is still reused for all
        #     execs (that was never the problem).
        container_persistent = false;
        docker_persist_across_processes = false;
        docker_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        docker_volumes = [
          "${vaultPath}:${vaultPath}"
          "${hermesHome}/.gitconfig:/root/.gitconfig:ro"
          # The homelab config repo, read-write: the agent edits + commits here.
          # The host-side hermes-repo-sync pushes the resulting feature branch.
          "${repoPath}:${repoPath}"
          # Host nix store + the nix-daemon socket (/nix/var/nix/daemon-socket,
          # mode 0666 → connectable from the user-namespaced container). With
          # NIX_REMOTE=daemon (below) the in-jail `nix` runs all builds via the
          # host daemon, so the agent can `nix flake check` / `nix develop -c just
          # …` to validate flake changes. ro: the daemon (not the client) writes
          # the store; connecting to the socket does not need the mount writable.
          "/nix:/nix:ro"
          # Make `nix` resolvable in the agent's LOGIN shells (see nixProfileScript):
          # docker_env.PATH below is wiped by the image's /etc/profile, so we also
          # add nix to PATH from /etc/profile.d, which IS sourced after that reset.
          "${nixProfileScript}:/etc/profile.d/hermes-nix.sh:ro"
        ];
        # The container does not inherit the agent's env. Set the vault path
        # inside it so the agent's `git -C "$OBSIDIAN_VAULT_PATH" commit` (per
        # SOUL.md) resolves. Same value as the host env var; the bind above puts
        # the vault at this exact path in-container.
        docker_env = {
          OBSIDIAN_VAULT_PATH = vaultPath;
          # Where the homelab config repo is mounted in-jail (== host path).
          HOMELAB_REPO_PATH = repoPath;
          # Route in-jail nix at the host nix-daemon over the mounted socket, so
          # no writable store is needed inside the ephemeral container.
          NIX_REMOTE = "daemon";
          NIX_CONFIG = "experimental-features = nix-command flakes";
          # CA bundle for flake-input fetches over HTTPS (resolved via /nix mount).
          NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          # Put the host `nix` on PATH while keeping the image's own dirs (where
          # python3/node for execute_code live) ahead of it.
          PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${pkgs.nix}/bin";
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

        ## Homelab Config Repo
        - This homelab's NixOS/IaC config repo is checked out at the path in
          `$HOMELAB_REPO_PATH`. Read it to understand the infrastructure and to
          make changes the user asks for. It is a Nix flake; `AGENTS.md` at its
          root documents the conventions and `just` commands.
        - NEVER commit to `main` (it is branch-protected and your commit would be
          rejected anyway). Work one FEATURE BRANCH per task, started from a fresh
          `origin/main`:
          `git -C "$HOMELAB_REPO_PATH" fetch origin && git -C "$HOMELAB_REPO_PATH" switch -c feat/<short-slug> origin/main`
        - Edit files with your file tools, then VALIDATE before committing:
          `cd "$HOMELAB_REPO_PATH" && nix develop -c just fmt && nix develop -c just nixos-check`
          (`nix` is available in your sandbox; `nix develop` provides `just`,
          `alejandra`, `tofu`, etc. from the repo's dev shell).
        - Commit with a meaningful message:
          `git -C "$HOMELAB_REPO_PATH" add -A && git -C "$HOMELAB_REPO_PATH" commit -m "<concise description>"`.
        - SAVING/SHARING: a host service pushes your feature branch to Forgejo
          automatically within seconds. You do NOT push, open PRs, merge, or
          deploy — you have neither the key nor the ability. The user reviews the
          branch, opens the pull request, and deploys (`colmena`) when at the host.
        - Never run `git reset --hard`, force-push, or switch back to commit on
          `main`. If a task is unrelated to the previous one, start a brand-new
          branch from `origin/main`.

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
    wants = ["agenix.target" "hermes-vault-sync.service" "hermes-repo-sync.service"];
    after = [
      "agenix.target"
      "tailscaled.service"
      "hermes-vault-git-setup.service"
      "hermes-vault-sync.service"
      "hermes-repo-sync.service"
    ];
    path = [pkgs.git pkgs.openssh pkgs.podman "/run/wrappers"];
    # Pin podman's *runtime dir* (XDG_RUNTIME_DIR) to the same systemd-managed
    # tmpfs as the runroot. This is the second half of decoupling the sandbox
    # from logind: storage.conf pins the storage *runroot*, but podman's libpod
    # rundir (pause process, sockets, container exit files) is XDG_RUNTIME_DIR-
    # derived and otherwise defaults to logind's /run/user/<uid>. That dir only
    # exists while user@<uid> (linger) is alive, so when it dies podman's
    # `version` precheck fails ("crun not found" / exit 125) and execute_code
    # reports "the sandbox Docker backend isn't running". Pinning it here puts the
    # rundir under /run/hermes-podman (created by RuntimeDirectory= below, always
    # present while the unit runs), so the sandbox no longer needs the user
    # session at all — verified: with this set and user@<uid> stopped, `podman
    # run` still launches the container. Hermes only sets XDG_RUNTIME_DIR when it
    # is unset (gateway.py _ensure_user_systemd_env), so this pin always wins.
    environment.XDG_RUNTIME_DIR = podmanRunRoot;
    serviceConfig = {
      # Pin the rootless-podman runroot to a deterministic, systemd-managed tmpfs
      # dir (owned by the service user, mode 0700, created before ExecStartPre).
      # This is the path referenced by podmanStorageConf's runroot=, so podman
      # never re-bakes a divergent /tmp or /run/user runroot into its DB. See the
      # podmanRunRoot block above.
      # Give the unit its own delegated cgroup subtree so the rootless container
      # runtime (crun, cgroupfs manager) can create per-container cgroups under
      # system.slice/hermes-agent.service without a systemd-user/D-Bus round trip.
      # This is the canonical way to run podman containers inside a systemd unit.
      Delegate = true;
      RuntimeDirectory = "hermes-podman";
      RuntimeDirectoryMode = "0700";
      # RuntimeDirectoryPreserve intentionally left at its default ("no"): with
      # ephemeral per-call containers there is no persistent container state worth
      # keeping across restarts, so systemd wipes + recreates /run/hermes-podman on
      # every stop/start. That makes the runroot self-cleaning — a stale pause.pid
      # (which lived under the runroot) can no longer survive a restart by
      # construction. Trade-off: while the service is stopped the runroot is absent,
      # so manual `sudo -u hermes podman` debugging must recreate the dir first.
      # First install ~/.config/containers/storage.conf (pins runroot/graphroot),
      # then self-heal a stale pause.pid / orphan helpers before the agent starts,
      # so the "cannot re-exec ... user namespace" / unwritable-runroot failures
      # cannot recur across reboots/redeploys. Both run as the hermes service user.
      ExecStartPre = ["${podmanStorageSetup}" "${podmanPauseGuard}"];
      # Rootless podman maps multiple sub-UIDs via the setuid newuidmap/newgidmap
      # helpers; NoNewPrivileges=true (set by the hermes module) makes the kernel
      # ignore their setuid bit, breaking userns setup. Relax it here — the risky
      # shell/code now runs jailed inside the podman container, so NNP on the host
      # agent process buys little once the container backend is in place.
      NoNewPrivileges = lib.mkForce false;
      # The hermes module ships TimeoutStopSec=90s, but the gateway drains for up to
      # drain_timeout=180s on stop/restart. With only 90s systemd SIGKILLs the agent
      # mid-drain, interrupting podman's container teardown and leaving orphan
      # conmon/pasta/podman-init — the root cause the ExecStartPre guard above mops up.
      # Give the drain room (>= 180s + margin) so shutdowns are clean and no orphans
      # are created in the first place. mkForce overrides the module's 90s.
      TimeoutStopSec = lib.mkForce 210;
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
    # Lingering is intentionally OFF. It used to be REQUIRED because podman's
    # libpod rundir defaulted to logind's /run/user/<uid> (only present while
    # user@<uid> lingers), so without it `podman version` failed and the sandbox
    # broke. That dependency is now removed by pinning XDG_RUNTIME_DIR to
    # /run/hermes-podman on the hermes-agent unit (see its `environment` above):
    # podman's rundir is a stable systemd-managed tmpfs, independent of any user
    # session. Verified 2026-06-22: with linger off + user@<uid> stopped + the
    # XDG_RUNTIME_DIR pin, `podman run` still launches the sandbox container.
    # Dropping linger also removes the exit-4 activation nuisance (NixOS reloading
    # the hermes user's --user units against a dead bus) — see
    # [[hermes-deploy-user995-exit4]]. NOTE: NixOS does not run `loginctl
    # disable-linger` when this option is removed; clear the leftover marker once
    # by hand: `sudo loginctl disable-linger hermes`.
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

  # ── Homelab config repo sync ──────────────────────────────────────────────
  # Reuses the git/ssh config installed by hermes-vault-git-setup (the
  # forgejo.homelab.local Host block + hermes-bot key apply to this repo too).
  # Clone-or-push the homelab config repo. Runs once at boot, then on a timer
  # (fetch + retry) and on a path trigger (instant push when the agent commits).
  systemd.services.hermes-repo-sync = {
    description = "Push the hermes-authored homelab config feature branches to Forgejo";
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

  # Slow timer: keeps origin/main fresh for the agent to branch from and retries
  # any pending feature-branch push.
  systemd.timers.hermes-repo-sync = {
    description = "Periodic homelab config repo fetch/push";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "1min";
    };
  };

  # Outbound: fire the push the moment the agent commits inside the jail.
  # .git/logs/HEAD is appended on every commit/branch op.
  systemd.paths.hermes-repo-sync = {
    description = "Push the homelab config feature branch when the agent commits";
    wantedBy = ["multi-user.target"];
    pathConfig = {
      PathModified = "${repoPath}/.git/logs/HEAD";
      Unit = "hermes-repo-sync.service";
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
  ];
}
