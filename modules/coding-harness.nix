{
  config,
  lib,
  pkgs,
  ...
}: let
  user = "amadeus";
  home = "/home/amadeus";

  # Central, single-source-of-truth MCP server list shared by every "coding
  # harness" (Claude Code, opencode) on hosts that import this module. Add an
  # entry here once; it's translated into each tool's native config syntax
  # below instead of being hand-duplicated per tool/per host.
  mcpServers = {
    axon-gateway = {
      url = "https://axon.homelab.local/mcp";
      # Name of the env var (see the axon-gateway-env secret each importing
      # host must declare) that each tool expands AT ITS OWN RUNTIME — the
      # token itself is never baked into these config files, only a
      # reference to the env var name. See `environment.interactiveShellInit`
      # below for where that env var actually gets set.
      tokenEnvVar = "AXON_GATEWAY_TOKEN";
    };
    # The Ventara deployment's own axon-gateway instance (nixos-ventara-ai
    # repo, services/axon-gateway) -- a SEPARATE gateway from the one above,
    # aggregating that repo's own backends (Prometheus/Loki MCP servers,
    # internal-dashboard's built-in MCP endpoint). Reached over the shared
    # Tailscale tailnet, not the homelab LAN, hence the .ts.net URL rather
    # than a *.homelab.local one.
    #
    # "axon-gateway-env" was already taken by the entry above, so this one's
    # token lives in its own secret (ventara-gateway-env, see
    # hasVentaraGatewayKey below) under its own env var name -- the two
    # tokens are unrelated and must not collide in the shell environment.
    ventara-gateway = {
      url = "https://ventara-vm01.dropbear-butterfly.ts.net:8093/mcp";
      tokenEnvVar = "VENTARA_GATEWAY_TOKEN";
    };
  };

  # opencode's own "plugin" config key (npm package names) and Claude Code's
  # "enabledPlugins" — left empty for now (mechanism only; the schema for
  # Claude Code's enabledPlugins has some doc ambiguity not worth guessing
  # at until there's a concrete plugin to enable). Extend here once needed.
  opencodePlugins = [];

  # Agent skills shipped from this repo's .opencode/skills/ (this module lives
  # in modules/, so ../.opencode/skills). Each skill is a <name>/SKILL.md folder
  # in the Agent Skills format. They are symlinked into ~/.claude/skills/ on
  # every activation, which is read by BOTH Claude Code and opencode (opencode
  # scans ~/.claude/skills as a Claude-compatible external-skill source). The
  # symlink points at the immutable Nix store path, so skills are read-only and
  # reproducible; a store-path change from an upgrade is re-linked each boot.
  # This includes the repo-native harness skills (claude-code-permissions,
  # code-review, conventional-commits, orchestrate-subagents,
  # subagent-driven-development) plus the shared skill library copied here from
  # the global ~/.agents/skills on the workstation (cue-kind-definition,
  # grill-with-docs, kubernetes-specialist, postgres, postgresql-table-design,
  # rust-async-patterns, rust-best-practices).
  repoSkillsDir = ../.opencode/skills;

  # Agent slash-commands shipped from this repo's .opencode/command/ (this
  # module lives in modules/, so ../.opencode/command). Each <name>.md file
  # becomes a /<name> command in BOTH harnesses: symlinked into
  # ~/.config/opencode/command/ (opencode) and ~/.claude/commands/ (Claude
  # Code). The $ARGUMENTS placeholder and `description` frontmatter key are
  # understood by both tools; opencode-only keys like `agent:` are silently
  # ignored by Claude Code, so one markdown file serves both.
  repoCommandsDir = ../.opencode/command;

  # Claude Code's MCP config uses `${VAR}` expansion syntax.
  claudeMcpServers =
    lib.mapAttrs (_: srv: {
      type = "http";
      url = srv.url;
      headers.Authorization = "Bearer \${${srv.tokenEnvVar}}";
    })
    mcpServers;

  # opencode uses `{env:VAR}` expansion syntax instead.
  opencodeMcpServers =
    lib.mapAttrs (_: srv: {
      type = "remote";
      url = srv.url;
      enabled = true;
      headers.Authorization = "Bearer {env:${srv.tokenEnvVar}}";
    })
    mcpServers;

  claudeConfigFragment = pkgs.writeText "claude-mcp-servers.json" (builtins.toJSON {
    mcpServers = claudeMcpServers;
  });

  # opencode permission guardrails. /tmp and opencode's own config dir are
  # reachable as external directories; the everyday git verbs (read/add/commit/
  # push) run without prompting. The github/force-push denials must still hold.
  #
  # Rule order is NOT author order: the jq merge in this module re-sorts object
  # keys alphabetically, and opencode evaluates the LAST matching rule. So the
  # patterns below are designed for ASCII sort order — the push allows sort
  # BEFORE the deny patterns ("git push *" < "git push --force*" because '*'
  # 0x2A < '-' 0x2D), which makes flag-FIRST force/github pushes hit the deny
  # last. A trailing flag (`git push origin --force`) still slips through the
  # broad allow — the deny list is a guardrail, not a boundary (AGENTS.md §8);
  # Forgejo's main-branch protection is the real gate. `git push github*` is
  # denied because the GitHub remote is a human-only mirror (AGENTS.md §6).
  # Everything unlisted keeps its default (ask).
  opencodePermissions = {
    external_directory = {
      "/home/amadeus/.config/opencode/**" = "allow";
      "/tmp/**" = "allow";
    };
    bash = {
      "git push" = "allow";
      "git push *" = "allow";
      "git push --force*" = "deny";
      "git push -f*" = "deny";
      "git push github*" = "deny";
      "git status*" = "allow";
      "git diff*" = "allow";
      "git log*" = "allow";
      "git show*" = "allow";
      "git fetch*" = "allow";
      "git add*" = "allow";
      "git commit*" = "allow";
    };
  };

  # Custom opencode theme — deployed to ~/.config/opencode/themes/
  mozart409KanagawaOrange = pkgs.writeText "mozart409-kanagawa-orange.json" ''
    {
      "$schema": "https://opencode.ai/theme.json",
      "defs": {
        "bg": "#1f1f28",
        "bgDark": "#16161d",
        "bgSurface": "#2a2a37",
        "fg": "#dcd7ba",
        "fgSubtle": "#a8a594",
        "fgMuted": "#727169",
        "blue": "#7fb4ca",
        "blueDark": "#7e9cd8",
        "blueLight": "#a3cbee",
        "purple": "#957fb8",
        "green": "#98bb6c",
        "teal": "#7aa89f",
        "yellow": "#c0a36e",
        "orange": "#ffa066",
        "orangeDark": "#e76f51",
        "orangeLight": "#f4a261",
        "red": "#e82424",
        "redSoft": "#ff5d62",
        "border": "#3a3a4a",
        "borderLight": "#4a4a5a"
      },
      "theme": {
        "primary": {"dark": "blue", "light": "blueDark"},
        "secondary": {"dark": "orange", "light": "orangeLight"},
        "accent": {"dark": "orange", "light": "orangeDark"},
        "error": {"dark": "red", "light": "redSoft"},
        "warning": {"dark": "orange", "light": "orangeLight"},
        "success": {"dark": "green", "light": "green"},
        "info": {"dark": "blue", "light": "blueLight"},
        "text": {"dark": "fg", "light": "fg"},
        "textMuted": {"dark": "fgSubtle", "light": "fgMuted"},
        "background": {"dark": "bg", "light": "bg"},
        "backgroundPanel": {"dark": "bgDark", "light": "bgDark"},
        "backgroundElement": {"dark": "bgSurface", "light": "bgSurface"},
        "border": {"dark": "border", "light": "border"},
        "borderActive": {"dark": "orange", "light": "orangeLight"},
        "borderSubtle": {"dark": "border", "light": "border"},
        "diffAdded": {"dark": "green", "light": "green"},
        "diffRemoved": {"dark": "redSoft", "light": "red"},
        "diffContext": {"dark": "fgMuted", "light": "fgMuted"},
        "diffHunkHeader": {"dark": "purple", "light": "purple"},
        "diffHighlightAdded": {"dark": "green", "light": "green"},
        "diffHighlightRemoved": {"dark": "redSoft", "light": "red"},
        "diffAddedBg": {"dark": "#2a3a2a", "light": "#2a3a2a"},
        "diffRemovedBg": {"dark": "#3a2a2a", "light": "#3a2a2a"},
        "diffContextBg": {"dark": "bgSurface", "light": "bgSurface"},
        "diffLineNumber": {"dark": "fgMuted", "light": "fgMuted"},
        "diffAddedLineNumberBg": {"dark": "#2a3a2a", "light": "#2a3a2a"},
        "diffRemovedLineNumberBg": {"dark": "#3a2a2a", "light": "#3a2a2a"},
        "markdownText": {"dark": "fg", "light": "fg"},
        "markdownHeading": {"dark": "orange", "light": "orangeLight"},
        "markdownLink": {"dark": "blue", "light": "blueLight"},
        "markdownLinkText": {"dark": "blue", "light": "blueLight"},
        "markdownCode": {"dark": "teal", "light": "teal"},
        "markdownBlockQuote": {"dark": "fgMuted", "light": "fgMuted"},
        "markdownEmph": {"dark": "orange", "light": "orangeLight"},
        "markdownStrong": {"dark": "orangeDark", "light": "orange"},
        "markdownHorizontalRule": {"dark": "fgMuted", "light": "fgMuted"},
        "markdownListItem": {"dark": "blue", "light": "blueLight"},
        "markdownListEnumeration": {"dark": "teal", "light": "teal"},
        "markdownImage": {"dark": "blueDark", "light": "blueDark"},
        "markdownImageText": {"dark": "fgSubtle", "light": "fgSubtle"},
        "markdownCodeBlock": {"dark": "fg", "light": "fg"},
        "syntaxComment": {"dark": "fgMuted", "light": "fgMuted"},
        "syntaxKeyword": {"dark": "orange", "light": "orangeLight"},
        "syntaxFunction": {"dark": "blue", "light": "blueLight"},
        "syntaxVariable": {"dark": "fg", "light": "fg"},
        "syntaxString": {"dark": "teal", "light": "teal"},
        "syntaxNumber": {"dark": "purple", "light": "purple"},
        "syntaxType": {"dark": "blueDark", "light": "blueDark"},
        "syntaxOperator": {"dark": "orange", "light": "orangeLight"},
        "syntaxPunctuation": {"dark": "fgSubtle", "light": "fgSubtle"}
      }
    }
  '';

  opencodeConfigFragment = pkgs.writeText "opencode-config.json" (builtins.toJSON ({
      "$schema" = "https://opencode.ai/config.json";
      theme = "mozart409-kanagawa-orange";
      mcp = opencodeMcpServers;
      permission = opencodePermissions;
    }
    // lib.optionalAttrs (opencodePlugins != []) {plugin = opencodePlugins;}));

  # ~/.claude.json holds Claude Code's own live session/account state
  # alongside `mcpServers`, and ~/.config/opencode/opencode.jsonc is written
  # to by opencode itself too — neither is safe to fully overwrite/symlink
  # from the Nix store. Deep-merge instead (jq's `*` recursively merges
  # objects, right-hand side wins per key) so Nix owns exactly the keys it
  # sets here and leaves everything else (auth, manually-added MCP servers,
  # etc.) untouched. Mirrors hermes-agent's config.yaml merge convention:
  # Nix wins for the keys it sets, never prunes.
  #
  # NB opencode's config file is `.jsonc`, NOT `.json` — that is what it
  # actually reads (verified on the reference host). Despite the extension it
  # must stay comment-free: jq cannot parse JSONC, so a hand-added `//` comment
  # would break this merge.
  mergeJson = pkgs.writeShellScript "coding-harness-merge-json" ''
    set -eu
    target="$1"
    fragment="$2"
    mkdir -p "$(dirname "$target")"
    if [ ! -f "$target" ]; then
      echo '{}' > "$target"
    fi
    tmp="$(mktemp)"
    ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" "$fragment" > "$tmp"
    mv "$tmp" "$target"
  '';

  # opencode's provider credentials live in auth.json, NOT in opencode.jsonc, and
  # opencode rewrites that file when other providers are added — so merge our key
  # in rather than overwriting. The value is piped through the environment (jq's
  # `env.`) instead of `--arg`, so it never appears in argv / `ps` output.
  #
  # Gated on the host declaring `age.secrets.opencode-zen-key`: each consumer
  # supplies its OWN per-host key file (see hosts/development), so a leak is
  # contained and revocation is per-host. Hosts that declare nothing (zeroclaw)
  # simply skip this — the attribute must not be referenced at all there, or
  # evaluation fails.
  hasOpencodeKey = config.age.secrets ? opencode-zen-key;

  # Same gating rationale as hasOpencodeKey above: only hosts that need the
  # ventara-gateway MCP entry to actually authenticate declare this secret
  # (currently just development); everywhere else the reference below must
  # not be evaluated at all, or eval fails with "attribute ... missing".
  hasVentaraGatewayKey = config.age.secrets ? ventara-gateway-env;

  applyOpencodeAuth = lib.optionalString hasOpencodeKey ''
    secret=${config.age.secrets.opencode-zen-key.path}
    authfile="${home}/.local/share/opencode/auth.json"
    if [ -r "$secret" ]; then
      set -a; . "$secret"; set +a
      if [ -n "''${OPENCODE_ZEN_API_KEY:-}" ]; then
        mkdir -p "$(dirname "$authfile")"
        [ -f "$authfile" ] || (umask 077; echo '{}' > "$authfile")
        tmp="$(mktemp)"
        if OPENCODE_ZEN_API_KEY="$OPENCODE_ZEN_API_KEY" ${pkgs.jq}/bin/jq \
             '.opencode = {type: "api", key: env.OPENCODE_ZEN_API_KEY}' \
             "$authfile" > "$tmp"; then
          (umask 077; mv "$tmp" "$authfile")
          chmod 0600 "$authfile"
        else
          rm -f "$tmp"
          echo "coding-harness: failed to merge opencode auth.json" >&2
        fi
      else
        echo "coding-harness: opencode-zen-key has no OPENCODE_ZEN_API_KEY" >&2
      fi
      unset OPENCODE_ZEN_API_KEY
    else
      echo "coding-harness: opencode-zen-key unreadable, skipping auth.json" >&2
    fi
  '';

  applyConfig = pkgs.writeShellScript "coding-harness-apply" ''
    set -u
    ${mergeJson} "${home}/.claude.json" "${claudeConfigFragment}" \
      || echo "coding-harness: failed to merge ~/.claude.json" >&2
    ${mergeJson} "${home}/.config/opencode/opencode.jsonc" "${opencodeConfigFragment}" \
      || echo "coding-harness: failed to merge opencode.jsonc" >&2

    # Deploy custom theme and ensure it's the active one
    mkdir -p "${home}/.config/opencode/themes"
    cp -f "${mozart409KanagawaOrange}" "${home}/.config/opencode/themes/mozart409-kanagawa-orange.json"

    # Earlier revisions of this module wrote opencode.json, which opencode does
    # not read. Remove it so there is exactly one config file and no confusion
    # about which one is live.
    rm -f "${home}/.config/opencode/opencode.json"

    # Agent skills: symlink each repo skill (see ${repoSkillsDir}) into
    # ~/.claude/skills/ so Claude Code and opencode can both load them.
    # Read-only store symlinks (never copied), refreshed every activation so an
    # upgraded store path is picked up. User-owned real skill dirs are left
    # untouched; only stale symlinks are pruned.
    mkdir -p "${home}/.claude/skills"
    current_skills=""
    for skill in "${repoSkillsDir}"/*/; do
      name="$(basename "$skill")"
      current_skills="$current_skills $name"
      target="${home}/.claude/skills/$name"
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        echo "coding-harness: keeping user-owned skill dir $target" >&2
        continue
      fi
      ln -sfn "$skill" "$target"
    done

    # Prune symlinks to skills that this repo no longer ships (their store path
    # changed, or the skill was removed), so a retired skill cannot linger.
    # Match on the literal target (readlink, not readlink -f) so a symlink to
    # an already-GC'd store path is still recognized and pruned.
    for target in "${home}"/.claude/skills/*; do
      [ -L "$target" ] || continue
      name="$(basename "$target")"
      case " $current_skills " in
        *" $name "*) continue ;;
      esac
      if readlink "$target" 2>/dev/null | grep -q '^/nix/store/'; then
        echo "coding-harness: pruning stale skill symlink $target" >&2
        rm -f "$target"
      fi
    done

    # Slash commands: symlink every ${repoCommandsDir}/*.md into BOTH
    # harnesses' user-level command dirs (~/.config/opencode/command/ for
    # opencode, ~/.claude/commands/ for Claude Code). Same store-symlink
    # convention as the skills above: read-only, refreshed every activation,
    # real user-owned files never touched, stale /nix/store symlinks pruned.
    mkdir -p "${home}/.config/opencode/command" "${home}/.claude/commands"
    current_commands=""
    for cmd in "${repoCommandsDir}"/*.md; do
      [ -e "$cmd" ] || continue
      name="$(basename "$cmd")"
      current_commands="$current_commands $name"
      ln -sfn "$cmd" "${home}/.config/opencode/command/$name"
      ln -sfn "$cmd" "${home}/.claude/commands/$name"
    done
    for target in "${home}/.config/opencode/command"/* "${home}/.claude/commands"/*; do
      [ -L "$target" ] || continue
      name="$(basename "$target")"
      case " $current_commands " in
        *" $name "*) continue ;;
      esac
      if readlink "$target" 2>/dev/null | grep -q '^/nix/store/'; then
        echo "coding-harness: pruning stale command symlink $target" >&2
        rm -f "$target"
      fi
    done
    ${applyOpencodeAuth}
  '';
in {
  systemd.services.coding-harness-config = {
    description = "Central MCP/plugin config for Claude Code + opencode (${user})";
    wantedBy = ["multi-user.target"];
    # Only needed once this reads a secret; harmless on hosts without one.
    after = ["agenix.target"];
    wants = ["agenix.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      ExecStart = applyConfig;
    };
  };

  # Export the axon-gateway MCP token into every interactive login shell, so
  # the `${AXON_GATEWAY_TOKEN}` / `{env:AXON_GATEWAY_TOKEN}` references
  # written into the JSON above actually resolve when `claude`/`opencode`
  # are launched by hand. Gated on readability so it's a silent no-op for
  # any user other than the secret's owner (each importing host must declare
  # `age.secrets.axon-gateway-env` with `owner = "amadeus";`).
  environment.interactiveShellInit =
    ''
      if [ -r "${config.age.secrets.axon-gateway-env.path}" ]; then
        set -a
        . "${config.age.secrets.axon-gateway-env.path}"
        set +a
      fi
    ''
    + lib.optionalString hasVentaraGatewayKey ''
      if [ -r "${config.age.secrets.ventara-gateway-env.path}" ]; then
        set -a
        . "${config.age.secrets.ventara-gateway-env.path}"
        set +a
      fi
    '';
}
