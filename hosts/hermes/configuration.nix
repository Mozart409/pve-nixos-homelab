{
  config,
  lib,
  pkgs,
  ...
}: let
  # ── Layout ────────────────────────────────────────────────────────────────
  # One unix user, several agent homes. `hermes` is a NORMAL user with a real
  # home, not the system account the upstream module would create, because the
  # same login also sits at a mosh prompt, holds the coding harness
  # (~/.claude, ~/.config/opencode) and keeps repo checkouts under ~/code.
  #
  # stateDir is deliberately NOT /home/hermes, though the rebuild plan sketched
  # it that way. The upstream module's activation script and tmpfiles rules
  # `chmod 2770` the stateDir unconditionally (nix/nixosModules.nix, the
  # "Directories" block is not gated on createUser), and a group-writable home
  # makes sshd's StrictModes refuse public-key auth for that user — which would
  # break the only interactive way into this host. Giving the agent its own
  # subdirectory keeps /home/hermes at 0700 and costs nothing: HERMES_HOME is
  # exported system-wide by `addToSystemPackages`, so `hermes`/`coding chat`
  # still find their state from any shell.
  humanHome = "/home/hermes";
  stateDir = "${humanHome}/agent";
  hermesHome = "${stateDir}/.hermes"; # == HERMES_HOME (module: stateDir/.hermes)

  # ── Restart nonce ─────────────────────────────────────────────────────────
  # hermes-agent reads its credentials, prompt and config at startup, and all of
  # it lives at STABLE paths a deploy rewrites in place: agenix drops secrets at
  # /run/agenix/<name>, and root activation scripts (re)write config.yaml,
  # SOUL.md and each profile's .env under ${hermesHome}. None of that changes
  # the generated unit file, so switch-to-configuration finds nothing to restart
  # and the agent keeps running with the previous prompt and credentials — the
  # long-standing "deploys don't restart hermes-agent" footgun in AGENTS.md §3.
  #
  # Bump this whenever a secret, any profile's SOUL.md / config.yaml, or a skill
  # changes; it is wired to restartTriggers on hermes-agent.
  secretNonce = "2026-09-23-rebuild-profiles";

  # Custom skills shipped from this repo, exposed read-only via the
  # `skills.external_dirs` config key. Hermes' skill loader rglobs each entry for
  # <name>/SKILL.md when building the prompt. Pointing at the immutable store
  # path keeps them reproducible and out of the mutable ~/.hermes/skills tree.
  # NB `./skills` is relative to THIS file, i.e. hosts/hermes/skills/.
  extraSkillsDir = ./skills;

  # ── Dashboard ─────────────────────────────────────────────────────────────
  dashboardHost = "hermes-dashboard.homelab.internal";
  dashboardPort = 9119;
  dashboardUrl = "https://${dashboardHost}";

  # Pocket ID is this homelab's OIDC provider. The dashboard's client is PUBLIC
  # (authorization code + PKCE S256) with access restricted to a single user, so
  # there is no client secret and this id is not a credential — every other
  # client in this lab uses a secret; this one deliberately does not, because
  # upstream does not support confidential clients for the dashboard yet.
  #
  # The issuer stays the tailnet name even though pocketid.homelab.{local,internal}
  # now resolve: the issuer URL is part of token identity and every other
  # consumer (forgejo, harbor, pgadmin, open-webui, romm, grafana) is pinned to
  # the ts.net one. Changing it is a fleet-wide migration, not a hermes decision.
  pocketIdIssuer = "https://pocketid.dropbear-butterfly.ts.net";
  dashboardClientId = "92fac046-8ab4-4081-bdef-e0795bac8c2c";

  # ── Shared config fragments ───────────────────────────────────────────────
  # Every profile gets these. Kept in one place so a change lands on all five.
  commonSettings = {
    provider = "deepseek";
    timezone = "Europe/Berlin";

    # Extra skill directories scanned in addition to the mutable
    # ~/.hermes/skills tree. The `skills` toolset must stay enabled for the
    # agent to see them.
    skills.external_dirs = ["${extraSkillsDir}"];

    # Approvals. This was `off` on the old host because "manual" blocked on an
    # interactive approval.request that the headless Open WebUI gateway could
    # never answer. `smart` (the new default) adjudicates each flagged command
    # with an auxiliary flash-tier model: auto-approve low risk, auto-deny
    # dangerous, escalate the uncertain middle — and `unattended_mode` /
    # `cron_mode` decide what an escalation does where no human is present.
    # So the headless hang we designed around is now a setting, not a reason to
    # disable the layer. See docs/hermes-agent-findings-2026-09-23.md §4.3.
    approvals = {
      mode = "smart";
      # A surface with no human (webhook, peer) denies rather than guesses.
      unattended_mode = "deny";
      # Cron likewise: a scheduled job that trips the guard should fail loudly
      # in its delivery, not silently do the dangerous thing at 03:00.
      cron_mode = "deny";
    };
    auxiliary.approval = {
      provider = "deepseek";
      model = "deepseek-v4-flash";
    };

    # Terminal/file/code tools run as host subprocesses of the agent — as the
    # `hermes` user, with no container. There is no libpod DB, runroot or pause
    # process, so the whole class of "execute_code → Docker version failed"
    # wedges is gone by construction. Confinement is the systemd unit sandbox
    # (ProtectSystem=strict, PrivateTmp, NoNewPrivileges, IPAddress*,
    # ReadOnlyPaths, the resource caps below), not a jail.
    terminal = {
      backend = "local";
      timeout = 180;
    };

    # Holographic memory: fully local, one SQLite FTS5 DB per profile home, no
    # infrastructure. NumPy (extraPythonPackages) enables the HRR algebra behind
    # probe/reason. The char limits gate the BUILT-IN `memory` toolset
    # (MEMORY.md/USER.md) — separate from the fact_store, same key, deep-merges.
    # 4x the module defaults (2200/1375).
    #
    # NOT a shared store: each profile's DB is its own. Cross-profile memory
    # needs Honcho, which is deferred — see docs/plans/hermes-rebuild.md §10.
    memory = {
      provider = "holographic";
      memory_char_limit = 8800;
      user_char_limit = 5500;
    };
    plugins.hermes-memory-store = {
      auto_extract = true;
      default_trust = 0.5;
      min_trust_threshold = 0.2;
    };

    # moshi-hooks: the phone-push plugin. Declaring it here makes the
    # registration Nix-owned so it survives a state-dir wipe, and it is the SOLE
    # reason `moshi-hook install` must not run on every boot — it rewrites
    # config.yaml with a conflicting list indent and corrupts the file. Keep Nix
    # the only steady-state writer of plugins.enabled. See ./moshi-hook.nix and
    # AGENTS.md §6.
    plugins.enabled = ["moshi-hooks"];
  };

  # Web config for the one profile that browses (research). SearXNG is ours and
  # free but SEARCH-ONLY; `web_extract` needs a provider with the extract
  # capability, and having only SearXNG configured is upstream issue #32698 —
  # exactly the dead end the old host had. Firecrawl's keyless tier is the
  # no-secret starting point; add a FIRECRAWL_API_KEY / EXA_API_KEY to that
  # profile's .env if the free tier throttles.
  webSettings = {
    web = {
      search_backend = "searxng";
      extract_backend = "firecrawl";
      extract_char_limit = 20000;
      cache_enabled = true;
      cache_ttl_minutes = 60;
    };
  };

  # ── MCP, per profile ──────────────────────────────────────────────────────
  # `services.hermes-agent.mcpServers` writes into $HERMES_HOME/config.yaml,
  # i.e. into the DEFAULT profile only — a secondary profile reads mcp_servers
  # from its own config.yaml and nothing else. Same story for credentials: the
  # module concatenates `environmentFiles` into the DEFAULT profile's .env
  # (nix/moduleCommon.nix), not into the unit's process environment, so a
  # profile that wants `${AXON_GATEWAY_TOKEN}` expanded must also list
  # axon-gateway-env in its OWN environmentFiles. Both halves or neither.
  #
  # Given deliberately to `infra` (this IS its job) and to `default` (the
  # catch-all), and withheld from coding/research/kb: every MCP server's whole
  # tool surface costs schema tokens on every LLM call, and the coding profile
  # reaches these backends through the nested harness's own MCP config anyway.
  axonMcpSettings = {
    mcp_servers.axon-gateway = {
      url = "https://axon.homelab.local/mcp";
      headers.Authorization = "Bearer \${AXON_GATEWAY_TOKEN}";
    };
  };

  # Cron result delivery. Upstream delivers the agent's final response itself
  # now — the agent does not send the message, so there is nothing to call in
  # the prompt — and tracks delivery separately from execution (a run whose
  # output never landed records `delivery_failed`, not a green `ok`). That is
  # what retires the hand-written `cron-result-delivery` skill.
  #
  # `homeassistant` is the target because HA already fans out to the phone. If
  # the moshi-hooks plugin turns out to fire on unattended cron sessions too,
  # this becomes redundant rather than wrong — verify with a throwaway
  # one-minute job before deciding (docs/plans/hermes-rebuild.md §8.1).
  cronSettings = {
    cron.deliver = "homeassistant";
  };

  # Toolset lists. Every enabled toolset costs tool-schema tokens on EVERY LLM
  # call, so these are deliberately minimal per profile rather than one generous
  # shared list. `browser` is absent everywhere: it has no engine configured on
  # this host, and a dead toolset still costs those tokens (findings §4.2).
  baseTools = ["file" "memory" "skills" "session_search"];

  # Per-platform tool configuration. The top-level `toolsets` is NOT consulted
  # per-platform: per hermes_cli/tools_config.py (`_get_platform_tools`) every
  # gateway platform resolves its tools ONLY from `platform_toolsets.<platform>`,
  # falling back to that platform's built-in preset when its key is absent. Pin
  # each platform so the surface is deterministic across redeploys.
  #
  # `cron` is always leaner than `cli`: jobs run unattended in a fresh session,
  # upstream warns that heavy toolsets bloat the schema on every call of every
  # job, `clarify` is useless with nobody there, and `cronjob` is force-disabled
  # inside cron runs anyway (anti-recursion guard).
  mkToolsets = tools: {
    toolsets = lib.unique tools;
    platform_toolsets = {
      # A human is present, so `clarify` is answerable and `cronjob` is how
      # schedules get created in the first place. lib.unique because a profile's
      # own list may already name cronjob.
      cli = lib.unique (tools ++ ["clarify" "cronjob"]);
      # Dropped for cron specifically: `clarify` has nobody to ask, `cronjob` is
      # force-disabled inside cron runs anyway (anti-recursion guard) so listing
      # it only pays its schema cost, and `delegation` is one of the toolsets
      # upstream singles out as prompt-bloating on every call of every job.
      # Per-job `enabled_toolsets` on cronjob.create still overrides this.
      cron = lib.subtractLists ["clarify" "cronjob" "delegation"] (lib.unique tools);
    };
  };
in {
  imports = [
    ../../modules/common.nix
    # XFS root, not btrfs: the guest disk is a zvol on a ZFS pool that is already
    # doing CoW, checksumming and zstd, so btrfs would stack a second CoW layer
    # and a second compression pass on top of it. This also gives a real 4 G swap
    # partition instead of a swapfile on a CoW subvolume, pins the disk by
    # /dev/disk/by-id, and enables weekly fstrim (hence `discard = "on"` on the
    # Proxmox disk in iac/main.tf).
    ../../modules/disko-xfs.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
    ../../modules/fluent-bit.nix
    ../../modules/caddy-http3.nix
    # Profiles: renders profiles/<name>/{config.yaml,SOUL.md,.env,memories/} and
    # owns hermes-config-check, which must now loop over all of them.
    ../../modules/hermes-profiles.nix
    # ── Coding harness (§6 of the rebuild plan) ──────────────────────────────
    # The same set `development` imports. They render Claude Code's and
    # opencode's config, this repo's skills and slash-commands, and the Moshi
    # hook wiring, into whichever account homelab.codingHarness names — here,
    # `hermes` itself. agent-user.nix is imported for its OPTIONS only;
    # homelab.agent.enable stays false, because on this host the whole machine
    # is the agent and the account is simply `hermes`.
    ../../modules/agent-user.nix
    ../../modules/coding-harness.nix
    ../../modules/claude-permissions.nix
    ../../modules/claude-settings-verify.nix
    ../../modules/repo-sync.nix
    ../../modules/moshi-hook-user.nix
    ../../modules/forgejo-cli.nix
    ../../modules/herdr.nix
    # Per-profile registration of the moshi-hooks plugin into each profile's
    # config.yaml, stamped per (profile, moshi-hook version).
    ./moshi-hook.nix
  ];

  networking.hostName = "homelab-hermes";

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

  # Compressed RAM swap as the first response to a memory spike, so the first
  # thing that happens is compression rather than IO on a 2-HDD pool shared by
  # every VM in the cluster. Same reasoning as `development`, and it matters
  # more here: a nested opencode/claude run plus a `nix develop` realisation is
  # exactly the spike this absorbs. NixOS gives zram priority over the disk
  # swap partition, so the disk stays a genuine last resort.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };

  # ── The account ───────────────────────────────────────────────────────────
  # One unprivileged user owning every profile home. The trade is stated
  # plainly: isolation between profiles is Hermes' bookkeeping, not the kernel —
  # `coding` and `research` share a uid and can read each other's .env. What
  # holds is the boundary that matters: `hermes` is not `amadeus`, has no sudo,
  # cannot read ~amadeus/.ssh (the colmena deploy key), and cannot deploy.
  #
  # One uid is also what makes the two features this rebuild is for work at all:
  # ONE dashboard that enumerates the invoking user's profiles/ directory, and
  # ONE multiplexing gateway. Per-profile unix users were considered and
  # rejected for exactly that reason.
  users.users.hermes = {
    isNormalUser = true;
    home = humanHome;
    description = "Hermes agent profiles + coding harness";
    shell = pkgs.zsh;
    # Primary group `hermes`, not the `users` default isNormalUser would pick.
    # The upstream module chowns its whole tree to ${cfg.user}:${cfg.group} and
    # makes every state directory 2770 setgid, so files the agent creates inherit
    # group `hermes` -- a user whose primary group is `users` would not be a
    # member of the group its own files land in.
    group = "hermes";
    # Keeps /home/hermes at 0700 so sshd's StrictModes accepts key auth. The
    # agent's own 2770 tree lives one level down, under ${stateDir}.
    homeMode = "0700";
    openssh.authorizedKeys.keys = config.homelab.users.amadeus.sshKeys;
    # User services (moshi-hook daemon, claude-permissions, herdr) start at boot
    # without a login. Also set by moshi-hook-user.nix; equal bool definitions
    # merge, so stating it here is documentation, not a conflict.
    linger = true;
  };
  users.groups.hermes = {};

  # No sudo, explicitly. An absent grant can be widened later by accident; a
  # deny cannot, and `sudo -l` says so in words.
  security.sudo.extraRules = [
    {
      users = ["hermes"];
      commands = [{command = "!ALL";}];
    }
  ];

  # Which account the harness modules configure. homelab.agent is NOT enabled —
  # there is no second account to create here.
  homelab.codingHarness = {
    user = "hermes";
    home = humanHome;
  };

  # ── Repo checkouts ────────────────────────────────────────────────────────
  # Sweeps every checkout under ~/code on a timer: fetch → `merge --ff-only`
  # (refuses on divergence) → plain `push` (no --force, ever). It never commits
  # or rebases and exits 0 on every skippable state, so a dirty tree is not a
  # failure. This is how the coding profile's commits reach Forgejo with no
  # human step.
  #
  # It pushes `main` directly — the same model as `development`, no PR
  # round-trip from a phone. That needs `hermes` on the push whitelist of each
  # protected `main` in Forgejo (see §5.3 of the rebuild plan). Nothing
  # auto-deploys from `main`: comin was removed 2026-09-08, so a push reaches
  # Forgejo and stops there until a human runs colmena.
  homelab.repoSync.hermes = {
    home = humanHome;
    sshKey = config.age.secrets.hermes-forgejo-ssh.path;
    push = true;
  };

  # Route Forgejo (LAN and tailnet) to the host's own key for this user. `Match`
  # precedes the `Host` blocks common.nix appends and ssh takes the first value
  # it finds, so this wins.
  programs.ssh.extraConfig = lib.mkBefore ''
    Match user hermes host forgejo.homelab.local,forgejo.homelab.internal,homelab-forgejo.dropbear-butterfly.ts.net
      Port 2222
      User forgejo
      IdentityFile ${config.age.secrets.hermes-forgejo-ssh.path}
      IdentitiesOnly yes
      IdentityAgent none
      StrictHostKeyChecking accept-new
  '';

  # Commit identity for this host's Forgejo account. `hermes` is a real Forgejo
  # account of its own (not amadeus's collaborator key, which is what
  # `development` uses), so commits from here are attributable to this host and
  # revocable per host.
  programs.git = {
    enable = true;
    config = {
      user.name = "hermes";
      user.email = "hermes@homelab.local";
      pull.rebase = true;
      init.defaultBranch = "main";
    };
  };

  # direnv + nix-direnv: `cd` into a checkout with an `.envrc` auto-loads its
  # flake devshell, cached so re-entry is instant. First use in a checkout still
  # needs a one-time `direnv allow`.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Ship the agent-related journals to the central Loki.
  services.loki-logs = {
    enable = true;
    units = [
      {
        unit = "hermes-agent.service";
        job = "hermes-agent";
      }
      {
        unit = "hermes-config-check.service";
        job = "hermes-config-check";
      }
      {
        unit = "repo-sync-hermes.service";
        job = "repo-sync";
      }
      {
        unit = "coding-harness-config.service";
        job = "coding-harness";
      }
      {
        unit = "hermes-moshi-profiles.service";
        job = "hermes-moshi-profiles";
      }
    ];
  };

  # ── Secrets ───────────────────────────────────────────────────────────────
  # Per-profile provider keys. A named profile resolves its providers ONLY from
  # its own .env, so each profile gets its own agenix file; modules/hermes-
  # profiles.nix concatenates them into profiles/<name>/.env at 0600. Note this
  # separates WHAT EACH PROFILE USES, not what it could read — one uid owns them
  # all (see the account comment above).
  age.secrets.hermes-default-env = {
    file = ../../secrets/hermes-default-env.age;
    owner = "hermes";
    mode = "0400";
  };
  age.secrets.hermes-coding-env = {
    file = ../../secrets/hermes-coding-env.age;
    owner = "hermes";
    mode = "0400";
  };
  age.secrets.hermes-research-env = {
    file = ../../secrets/hermes-research-env.age;
    owner = "hermes";
    mode = "0400";
  };
  age.secrets.hermes-kb-env = {
    file = ../../secrets/hermes-kb-env.age;
    owner = "hermes";
    mode = "0400";
  };
  age.secrets.hermes-infra-env = {
    file = ../../secrets/hermes-infra-env.age;
    owner = "hermes";
    mode = "0400";
  };

  # opencode-zen provider key (env-file: OPENCODE_ZEN_API_KEY=...). Declared
  # under the GENERIC attribute name modules/coding-harness.nix looks for, while
  # the file itself stays per-host. It is also the unattended coding path's
  # credential: opencode authenticates from a key on disk, Claude Code from an
  # interactive OAuth login, which is why cron jobs shell out to `opencode`.
  age.secrets.opencode-zen-key = {
    file = ../../secrets/hermes-opencode-zen-key.age;
    owner = "hermes";
    mode = "0400";
  };

  # Axon MCP gateway bearer token (AXON_GATEWAY_TOKEN=...). Read by hermes-agent
  # (to expand the mcp_servers header) AND by the harness, which sources it into
  # interactive shells so `claude`/`opencode` resolve their own MCP config.
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    owner = "hermes";
    mode = "0400";
  };

  # The Ventara deployment's own axon-gateway instance — a separate gateway on
  # the shared tailnet, registered by modules/coding-harness.nix. Without this
  # secret that MCP entry exists but never authenticates.
  age.secrets.ventara-gateway-env = {
    file = ../../secrets/ventara-gateway-env.age;
    owner = "hermes";
    mode = "0400";
  };

  # AgentMail API key (AGENTMAIL_API_KEY=am_...) for the agent's own inbox.
  age.secrets.hermes-agentmail-key = {
    file = ../../secrets/hermes-agentmail-key.age;
    owner = "hermes";
    mode = "0400";
  };

  # This host's Forgejo account key. RE-MINTED for the rebuild: the file used to
  # hold the `hermes-bot` account's key, which served the Obsidian vault and the
  # feature-branch flow — both retired. Owned by hermes because ssh reads
  # IdentityFile as the running process.
  age.secrets.hermes-forgejo-ssh = {
    file = ../../secrets/hermes-forgejo-ssh.age;
    owner = "hermes";
    mode = "0400";
  };

  # Moshi pairing token (raw text, NOT KEY=value — read directly by the pair
  # script in modules/moshi-hook-user.nix).
  #
  # It is UNVERIFIED whether one Moshi account token can pair three hosts
  # (development, zeroclaw, hermes) at once, or whether pairing a third
  # invalidates the first. Verify on this host before assuming push works.
  age.secrets.moshi-device-id = {
    file = ../../secrets/moshi-device-id.age;
    owner = "hermes";
    group = "hermes";
    mode = "0440";
  };

  # ── The agent ─────────────────────────────────────────────────────────────
  services.hermes-agent = {
    enable = true;

    # We own the account (above); the module must not create a system user of
    # its own. stateDir is one level below the login's home — see the layout
    # comment at the top of this file for why it is not /home/hermes itself.
    user = "hermes";
    group = "hermes";
    createUser = false;
    inherit stateDir;

    # Puts the `hermes` CLI on PATH and exports HERMES_HOME system-wide, so an
    # interactive shell shares state with the gateway and `hermes -p coding chat`
    # (or the auto-generated ~/.local/bin/coding wrapper) works from any cwd.
    addToSystemPackages = true;

    # ── Web dashboard ──────────────────────────────────────────────────────
    # Bound to LOOPBACK, and still authenticated. v2026.9.21 changed the rule
    # the rebuild plan was written against: declaring a non-loopback
    # `dashboard.public_url` engages the auth gate *even when the backend binds
    # to loopback*, and the hostname in that URL is accepted as an exact Host /
    # WebSocket Origin value (so the DNS-rebinding guard is satisfied by the
    # proxied request). That is strictly better than the plan's 0.0.0.0 bind:
    # Caddy is the only thing that can reach the socket at all, AND every
    # request through it must carry a verified Pocket ID session.
    backend = {
      mode = "dashboard";
      host = "127.0.0.1";
      port = dashboardPort;
    };

    # Host-wide env. Per-PROFILE provider keys live in each profile's own .env
    # (rendered by modules/hermes-profiles.nix); these are the values the
    # default profile and the gateway itself need.
    environmentFiles = [
      config.age.secrets.hermes-default-env.path
      config.age.secrets.axon-gateway-env.path
      config.age.secrets.hermes-agentmail-key.path
    ];

    environment = {
      # Agent clock. Hermes resolves the time it injects into the conversation
      # via hermes_time.now(), which reads HERMES_TIMEZONE first (then the
      # config.yaml `timezone` key, then server-local). Plain `TZ` is NOT
      # consulted by that resolver — this, not TZ, is what makes the agent
      # report Berlin. (Do not set time.timeZone here; common.nix already does.)
      HERMES_TIMEZONE = "Europe/Berlin";
      # SearXNG on the containers host, backing `web_search`. The .internal name
      # resolves from here and carries a step-ca cert; MagicDNS does not.
      SEARXNG_URL = "https://searxng.homelab.internal";
      # httpx (used by the searxng provider) re-initialises its SSL context and
      # fails CERTIFICATE_VERIFY_FAILED without this, even though Python's
      # default_verify_paths points at the same bundle.
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    # ── The DEFAULT profile ────────────────────────────────────────────────
    # These settings describe $HERMES_HOME itself, which IS the default
    # profile. The other four are rendered under profiles/ by
    # modules/hermes-profiles.nix.
    settings =
      commonSettings
      // cronSettings
      // (mkToolsets (baseTools ++ ["cronjob"]))
      // {
        # Cheap tier on purpose: this profile is the switchboard. It owns the
        # multiplexer and the dashboard and routes real work to a sibling.
        model = "deepseek-v4-flash";

        # One gateway serves every profile. v2026.9.21 enforces a host-wide
        # singleton lock (one `hermes gateway run` per machine; a second starts
        # observe-only), and multiplexing — on by default, stated here so it
        # cannot drift — makes the default profile's gateway serve all of them,
        # picking up profiles created later without a restart. Per-profile
        # lifecycle is `hermes -p <name> gateway stop|start`, not a second unit.
        #
        # Footgun: the module's ExecStart is `hermes gateway run --replace`, and
        # upstream issue #119837 reports that `--replace` skips the host-lock
        # refusal. With a single unit that race is unlikely; verify
        # `hermes gateway status` reports exactly one owner after boot.
        gateway.multiplex_profiles = true;

        dashboard = {
          # Declaring this is what engages the auth gate on a loopback bind, and
          # it is what the OAuth callback is built from: <public_url>/auth/callback,
          # verbatim. That exact URL must be registered on the Pocket ID client.
          public_url = dashboardUrl;
          # Caddy runs on this host, so loopback trust already covers it.
          # Listed explicitly so a future move of the TLS terminator to another
          # host is a one-line change rather than a debugging session.
          trusted_proxies = ["127.0.0.1"];
          oauth = {
            provider = "self-hosted";
            self_hosted = {
              issuer = pocketIdIssuer;
              client_id = dashboardClientId;
              scopes = "openid profile email";
            };
          };
        };
      };

    # Hermes reads SOUL.md and memories/ from HERMES_HOME, NOT from the working
    # directory — `documents` would install them into workspace/ where nothing
    # reads them. (This was open question §3.2 in the findings doc; confirmed
    # against nix/moduleCommon.nix on v2026.9.21, which now asserts on
    # `documents` without an explicit workingDirectory for exactly this reason.)
    hermesHomeFiles = {
      "SOUL.md" = ./souls/default.md;
      "memories/USER.md" = ./souls/user.md;
    };

    # MCP servers. axon-gateway aggregates the homelab backends behind one
    # authenticated endpoint; the header value is expanded by Hermes from the
    # agenix-loaded env var at runtime, never baked into a store path.
    mcpServers = {
      axon-gateway = {
        url = "https://axon.homelab.local/mcp";
        headers.Authorization = "Bearer \${AXON_GATEWAY_TOKEN}";
      };
      agentmail = {
        url = "https://mcp.agentmail.to/mcp";
        headers."x-api-key" = "\${AGENTMAIL_API_KEY}";
      };
    };

    # NumPy enables Holographic's HRR algebra (probe/reason).
    extraPythonPackages = [pkgs.python312Packages.numpy];

    # Host toolchain for the `local` backend. The module only puts
    # [bash coreutils git] on the service PATH, and under `local` the agent's
    # terminal/execute_code tools inherit exactly that — so everything they need
    # is provisioned here:
    #   python3/nodejs      → execute_code + ordinary shell work
    #   curl/jq/grep/sed/awk/find → everyday tooling
    #   nix                 → `nix develop -c just fmt` and scoped `nix eval`;
    #                         talks to the host nix-daemon natively
    #   openssh             → `git push` over ssh
    #   opencode/claude-code → the harness the coding profile shells out to
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
      opencode
      claude-code
    ];
  };

  # ── The other four profiles ───────────────────────────────────────────────
  homelab.hermesProfiles.profiles = {
    coding = {
      description = "Drives opencode/claude in ~/code; the only profile with a shell.";
      soul = ./souls/coding.md;
      memories."USER.md" = ./souls/user.md;
      environmentFiles = [config.age.secrets.hermes-coding-env.path];
      settings =
        commonSettings
        // cronSettings
        // (mkToolsets (baseTools ++ ["terminal" "code_execution" "delegation" "cronjob"]))
        // {
          model = "deepseek-v4-pro";

          # Checkpoints: snapshot a project before destructive operations into a
          # shadow git store, restorable with /rollback. Opt-in upstream
          # (`enabled: false` by default) and enabled for THIS profile only —
          # it is the one that edits files and shells out to other agents. The
          # store is per Hermes home, so one 500 MB cap, not five.
          #
          # `git gc` reclaims space on a background sweep that can take tens of
          # seconds; on a 4-core guest also running nested opencode, keep the
          # sweep to once a day.
          #
          # These are NOT backups: 7-day retention, working-directory scope.
          # Forgejo is the durable copy, which is the other reason this profile
          # pushes main.
          checkpoints = {
            enabled = true;
            max_snapshots = 20;
            max_total_size_mb = 500;
            max_file_size_mb = 10;
            auto_prune = true;
            retention_days = 7;
            min_interval_hours = 24;
          };
        };
    };

    research = {
      description = "Reading and synthesis; web tools, no shell.";
      soul = ./souls/research.md;
      memories."USER.md" = ./souls/user.md;
      environmentFiles = [config.age.secrets.hermes-research-env.path];
      settings =
        commonSettings
        // webSettings
        // cronSettings
        // (mkToolsets (baseTools ++ ["web" "cronjob"]))
        // {
          model = "deepseek-v4-pro";
        };
    };

    kb = {
      description = "Notes and knowledge capture; memory-first, no shell, no web.";
      soul = ./souls/kb.md;
      memories."USER.md" = ./souls/user.md;
      environmentFiles = [config.age.secrets.hermes-kb-env.path];
      settings =
        commonSettings
        // (mkToolsets baseTools)
        // {
          model = "deepseek-v4-flash";
        };
    };

    infra = {
      description = "Homelab observability via the axon-gateway MCP backends.";
      soul = ./souls/infra.md;
      memories."USER.md" = ./souls/user.md;
      environmentFiles = [
        config.age.secrets.hermes-infra-env.path
        # Expands ${AXON_GATEWAY_TOKEN} in the mcp_servers header below.
        config.age.secrets.axon-gateway-env.path
      ];
      settings =
        commonSettings
        // axonMcpSettings
        // cronSettings
        // (mkToolsets (baseTools ++ ["cronjob"]))
        // {
          model = "deepseek-v4-pro";
          # Deliberately NO terminal/code_execution: everything this profile
          # needs arrives through MCP, and the axon gateway's tools are already
          # a wide read surface over the whole fleet. Adding a shell on top
          # would widen the blast radius of a bad tool result for no capability
          # gain — it has no sudo and no deploy key either way.
        };
    };
  };

  # ── Agent unit hardening ──────────────────────────────────────────────────
  systemd.services.hermes-agent = {
    wants = ["agenix.target"];
    after = ["agenix.target" "tailscaled.service"];
    # Config, SOUL.md and the .env files are written at stable paths, so the
    # unit definition does not change when they do. See secretNonce above.
    restartTriggers = [secretNonce];
    serviceConfig = {
      # ── Config integrity ──────────────────────────────────────────────────
      # Under the `local` backend the agent's tools run AS the hermes user and
      # these files are owned by hermes, so without this the agent could rewrite
      # its own model and system prompt at runtime. They are (re)written on every
      # deploy by ROOT activation scripts that run OUTSIDE this unit's mount
      # namespace, so binding them read-only here stops the running agent
      # without breaking the Nix merge. Nix stays the source of truth.
      #
      # Single files inside the module's ReadWritePaths; systemd's most-specific
      # -path rule keeps the rest writable — memory DB, cron jobs, sessions,
      # checkpoints, logs. The four secondary profiles' pairs are appended by
      # modules/hermes-profiles.nix (unitOption concatenates list definitions).
      #
      # Upstream v2026.9.21 also hard-blocks write_file/patch on ~/.ssh, .env
      # and protected instruction files — keep ours as well: a bind mount is
      # enforced by the kernel, theirs by the agent.
      ReadOnlyPaths = [
        "${hermesHome}/config.yaml"
        "${hermesHome}/SOUL.md"
      ];

      # ── Network allow-list ────────────────────────────────────────────────
      # The agent runs a shell and has web tools, so a prompt injection in a
      # fetched page is a shell on the LAN. Confine it to the peers it actually
      # needs; the internet (DeepSeek, AgentMail, opencode-zen, Anthropic, nix
      # substituters) stays open because the deny list only covers private
      # ranges. This is a cgroup BPF filter, so it applies to every subprocess —
      # the nested opencode/claude runs included.
      #   .145 dns, .1 router (second resolver in modules/common.nix)
      #   .178 forgejo (repo push)      .152 mcp (axon gateway)
      #   .149 containers (searxng)     .102 pocketid (OIDC discovery)
      # 100.64.0.0/10 is NOT fully denied: the tailnet carries the Pocket ID
      # issuer and the ventara-gateway MCP, and there is no LAN equivalent for
      # the latter. Denying CGNAT wholesale and allowing back two moving
      # addresses would break on every tailnet re-IP; the tailnet is a trusted
      # network here and the host firewall (below) is what bounds inbound.
      IPAddressDeny = ["192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12"];
      IPAddressAllow = [
        "localhost"
        "192.168.2.145"
        "192.168.2.1"
        "192.168.2.178"
        "192.168.2.152"
        "192.168.2.149"
        "192.168.2.102"
      ];

      # ── Resource caps ─────────────────────────────────────────────────────
      # Raised from the old host's 3G/512/512. One gateway now serves five
      # profiles, and the coding profile shells out to a nested node/opencode
      # process that may itself realise a devShell — either exceeds the old caps
      # on its own. Deliberately NO hard MemoryMax: a pure `nix eval` runs
      # client-side in THIS unit and a tight cap would OOM-kill legitimate
      # scoped evals; heavy builds run in nix-daemon.service's own cgroup.
      TasksMax = 4096;
      LimitNPROC = 4096;
      MemoryHigh = "6G";

      # The module ships TimeoutStopSec=90s, but the gateway drains up to
      # drain_timeout=180s on stop/restart; 90s SIGKILLs it mid-drain.
      TimeoutStopSec = lib.mkForce 210;
    };
  };

  # ── Dashboard vhost ───────────────────────────────────────────────────────
  services.caddy = {
    enable = true;
    virtualHosts."${dashboardHost} hermes-dashboard.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          # 127.0.0.1, never `localhost`: /etc/resolv.conf on these hosts lists a
          # dead `nameserver ::1`, and every `reverse_proxy localhost:…` vhost
          # hung on that timeout.
          reverse_proxy 127.0.0.1:${toString dashboardPort}
        }
      '';
    };
  };

  # ── Firewall — no bypass path ─────────────────────────────────────────────
  # NOTE what is absent: `trustedInterfaces = ["tailscale0"]`, which every other
  # host in this repo sets. That line accepts EVERY port from the tailnet, and
  # this is the one host running an agent with a shell — so nothing here is open
  # merely because of the interface it arrived on. The dashboard's auth gate
  # would still challenge a direct connection, but a single door with two locks
  # beats two doors with one each.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22 # ssh (also the mosh handshake)
      443 # Caddy: the dashboard vhost, and nothing else
      9100 # node exporter (otel scrapes from 192.168.2.135)
    ];
    allowedUDPPortRanges = [
      {
        from = 60000;
        to = 61000;
      } # mosh
    ];
    # tailscaled's own inbound port. Without it every session is relayed through
    # DERP instead of connecting directly. Not a hole — it is wireguard.
    allowedUDPPorts = [config.services.tailscale.port];
    #
    # Deliberately NOT listed:
    #   9119 — the dashboard. Reachable only from 127.0.0.1, i.e. only through
    #          Caddy. This is the whole point.
    #   8642 — the api_server. Gone entirely: no key, no vhost, no listener.
    # `checkReversePath = "loose"` comes from modules/tailscale.nix and must
    # stay. Tailscale ACLs gate ports before this firewall ever sees them, but
    # they live outside this repo — treat them as a bonus, never as the control.
  };

  environment.systemPackages = with pkgs; [
    # keep-sorted start
    bat
    btop
    # bun + nodejs: opencode's global plugins (moshi-hooks.ts, herdr-agent-state.js)
    # import @opencode-ai/plugin and bun:sqlite, and opencode bootstraps their
    # node_modules on first run.
    bun
    claude-code
    curl
    eza
    fd
    fzf
    htop
    jq
    neovim
    nodejs
    opencode
    ripgrep
    tmux
    wget
    # keep-sorted end
  ];

  # Convenience aliases for the interactive account. The per-profile wrappers
  # (~/.local/bin/coding, /research, …) are generated by hermes itself.
  environment.shellAliases = {
    op = "opencode";
    cl = "claude";
  };
}
