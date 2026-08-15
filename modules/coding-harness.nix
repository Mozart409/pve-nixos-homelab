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

  opencodeConfigFragment = pkgs.writeText "opencode-config.json" (builtins.toJSON ({
      "$schema" = "https://opencode.ai/config.json";
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
  environment.interactiveShellInit = ''
    if [ -r "${config.age.secrets.axon-gateway-env.path}" ]; then
      set -a
      . "${config.age.secrets.axon-gateway-env.path}"
      set +a
    fi
  '';
}
