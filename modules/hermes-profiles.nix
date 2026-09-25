# Declarative Hermes *profiles* — several agent homes under one unix user.
#
# A Hermes profile is just a second HERMES_HOME: a directory under
# `$HERMES_HOME/profiles/<name>/` carrying its own `config.yaml`, `.env`,
# `SOUL.md`, `memories/`, `sessions/`, `skills/`, cron jobs, checkpoints and
# `state.db`. Upstream recognises a directory as a profile only once it holds
# one of those identity files, so rendering `config.yaml` + `SOUL.md` is what
# makes a profile exist — there is no `hermes profile create` to run.
#
# Why this module exists: the upstream NixOS module is SINGLE-home. `stateDir`,
# `settings`, `hermesHomeFiles`, `environment` and `environmentFiles` all
# describe exactly one Hermes home (the default profile, at `$HERMES_HOME`
# itself), and there is no profile option. Everything here renders the
# SECONDARY profiles in the same conventions upstream uses for the primary one:
#
#   - `config.yaml` is DEEP-MERGED into whatever is on disk, Nix winning per
#     key, never pruning — identical to upstream's `hermes-config-merge`. The
#     agent may add keys of its own; Nix owns the keys it names.
#
#     WARNING: "never pruning" means REMOVING A SETTING HERE DOES NOT REMOVE IT
#     FROM THE HOST. Deleting a key from Nix only stops re-asserting it; the
#     value already written to config.yaml stays and the agent keeps honouring
#     it. To remove something you must override it with the value you want, or
#     delete the file and let activation regenerate it. Lists are replaced
#     rather than merged (deep_merge recurses only when both sides are dicts),
#     so a list Nix stops declaring is frozen at its last value. Re-verified
#     against v2026.9.21 and upstream main on 2026-09-25 — see AGENTS.md §6,
#     "Hermes `config.yaml` Is Deep-Merged and NEVER Pruned".
#   - `.env` is concatenated from agenix-decrypted env files at 0600.
#   - `SOUL.md` and `memories/` are installed into the profile home, because
#     Hermes reads the system prompt and memory from HERMES_HOME and NOT from
#     the working directory (upstream's `hermesHomeFiles`, not `documents`).
#   - each rendered `config.yaml`/`SOUL.md` is added to the agent unit's
#     `ReadOnlyPaths`, so the running agent cannot rewrite its own model or
#     system prompt. A kernel bind beats the agent's own file-guard.
#
# One systemd unit still serves every profile: `v2026.9.21` enforces a
# host-wide gateway singleton, and `gateway.multiplex_profiles` (on by default)
# makes the default profile's gateway serve all the others. This module
# therefore generates FILES and activation steps, never units.
#
# It also owns `hermes-config-check`, which has to loop over every profile:
# Hermes fails OPEN on an unparseable `config.yaml` (gateway/run.py's
# `_load_gateway_config` swallows the YAML error and substitutes an empty
# dict), so with N profiles there are N files whose corruption would silently
# demote an agent to built-in defaults. See AGENTS.md §6.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.hermesProfiles;
  hermesCfg = config.services.hermes-agent;

  inherit (hermesCfg) user group;
  hermesHome = "${hermesCfg.stateDir}/.hermes";
  profileDir = name: "${hermesHome}/profiles/${name}";

  yamlFormat = pkgs.formats.yaml {};

  pythonWithYaml = pkgs.python3.withPackages (ps: [ps.pyyaml]);

  # Deep-merge a Nix-generated config into the live file, Nix winning per key.
  # A verbatim re-implementation of upstream's nix/configMergeScript.nix so the
  # secondary profiles behave exactly like the primary one: keys Nix sets are
  # authoritative, keys it does not set are preserved, nothing is ever pruned.
  configMerge = pkgs.writeScript "hermes-profile-config-merge" ''
    #!${pythonWithYaml}/bin/python3
    import json, sys, yaml
    from pathlib import Path

    nix_json, config_path = sys.argv[1], Path(sys.argv[2])
    nix = json.loads(Path(nix_json).read_text())

    existing = {}
    if config_path.exists():
        try:
            existing = yaml.safe_load(config_path.read_text()) or {}
        except yaml.YAMLError as exc:
            # Leave the broken file alone and let hermes-config-check deal with
            # it; merging into a half-parsed document would destroy evidence.
            print(f"hermes-profile-config-merge: {config_path} unparseable, "
                  f"writing Nix config only ({exc})", file=sys.stderr)
            existing = {}

    def deep_merge(base, override):
        result = dict(base)
        for k, v in override.items():
            if k in result and isinstance(result[k], dict) and isinstance(v, dict):
                result[k] = deep_merge(result[k], v)
            else:
                result[k] = v
        return result

    config_path.write_text(
        yaml.dump(deep_merge(existing, nix), default_flow_style=False, sort_keys=False)
    )
  '';

  # Validate, minimally repair, and GATE one config.yaml. Moved here from
  # hosts/hermes/configuration.nix unchanged in behaviour — it already took the
  # path as argv[1], so the only change is that the unit now calls it once per
  # profile instead of once.
  configCheck = pkgs.writeScript "hermes-config-check" ''
    #!${pythonWithYaml}/bin/python3
    """Validate, minimally repair, and gate one hermes config.yaml."""
    import os
    import shutil
    import sys
    import time
    from pathlib import Path

    import yaml

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"hermes-config-check: {path} does not exist yet; nothing to check")
        sys.exit(0)

    raw = path.read_text()


    def parse(text):
        return yaml.safe_load(text) or {}


    def normalize_sequence_runs(text):
        """Re-indent mixed-depth block-sequence runs and drop exact duplicates.

        The known corruption is two `- moshi-hooks` items at different depths under
        `plugins.enabled:` (the Nix merge dumps at 2-space, moshi-hook writes at
        4-space, and each inserts a duplicate it cannot see). A run of consecutive
        `- ` lines always belongs to ONE sequence, so flattening the run to its
        shallowest indent and dropping repeats restores a parseable document
        without disturbing anything else in the file.
        """
        lines = text.splitlines()
        out = []
        i = 0
        while i < len(lines):
            if not lines[i].lstrip().startswith("- "):
                out.append(lines[i])
                i += 1
                continue
            run = []
            while i < len(lines) and lines[i].lstrip().startswith("- "):
                run.append(lines[i])
                i += 1
            indent = min(len(ln) - len(ln.lstrip()) for ln in run)
            seen = set()
            for ln in run:
                item = ln.strip()
                if item in seen:
                    continue
                seen.add(item)
                out.append(" " * indent + item)
        return "\n".join(out) + "\n"


    changed = False
    try:
        data = parse(raw)
    except yaml.YAMLError as exc:
        print(f"hermes-config-check: {path} is not valid YAML:\n{exc}", file=sys.stderr)
        try:
            data = parse(normalize_sequence_runs(raw))
        except yaml.YAMLError:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            backup = path.with_suffix(f".yaml.corrupt.{stamp}")
            shutil.copy2(path, backup)
            print(
                "hermes-config-check: automatic repair FAILED. Starting hermes now "
                "would fail open to an EMPTY config and silently ignore every "
                "override (model, toolsets, mcp_servers, ...). Blocking hermes-agent. "
                f"Corrupt copy saved at {backup}.",
                file=sys.stderr,
            )
            sys.exit(1)
        changed = True
        print("hermes-config-check: repaired mixed-indent/duplicate sequence items")

    plugins = data.get("plugins")
    if isinstance(plugins, dict) and isinstance(plugins.get("enabled"), list):
        deduped = list(dict.fromkeys(plugins["enabled"]))
        if deduped != plugins["enabled"]:
            plugins["enabled"] = deduped
            changed = True
            print("hermes-config-check: de-duplicated plugins.enabled")

    # An empty/absent model is unrecoverable at runtime: there is no env fallback,
    # so the agent would start and 400 on the first message. Fail here instead.
    if not data.get("model"):
        print(
            "hermes-config-check: no `model` set in config.yaml — the agent would "
            "send an empty model and every request would fail. Blocking hermes-agent.",
            file=sys.stderr,
        )
        sys.exit(1)

    if changed:
        mode = path.stat().st_mode & 0o777
        tmp = path.with_suffix(".yaml.tmp")
        with tmp.open("w") as fh:
            yaml.dump(data, fh, default_flow_style=False, sort_keys=False)
        os.chmod(tmp, mode)
        tmp.replace(path)
        print(f"hermes-config-check: rewrote {path}")

    print(f"hermes-config-check: OK (model={data.get('model')!r})")
  '';

  # One profile's activation steps. Runs as root during activation (after
  # `users` and agenix's `setupSecrets`, so the account and /run/agenix exist).
  renderProfile = name: profile: let
    dir = profileDir name;
    nixJson = pkgs.writeText "hermes-profile-${name}.json" (builtins.toJSON profile.settings);
    soulFile =
      if builtins.isPath profile.soul || lib.isStorePath profile.soul
      then profile.soul
      else pkgs.writeText "hermes-soul-${name}.md" profile.soul;
    memoryFiles =
      lib.mapAttrsToList (
        rel: value: let
          src =
            if builtins.isPath value || lib.isStorePath value
            then value
            else pkgs.writeText "hermes-${name}-${baseNameOf rel}" value;
        in ''
          install -o ${user} -g ${group} -m 0640 -D ${src} ${dir}/memories/${rel}
        ''
      )
      profile.memories;
    envLines =
      lib.mapAttrsToList (k: v: "printf '%s=%s\\n' ${lib.escapeShellArg k} ${lib.escapeShellArg v} >> \"$tmpenv\"")
      profile.environment;
  in ''
    # ── profile: ${name} ──────────────────────────────────────────────────
    install -d -o ${user} -g ${group} -m 0750 ${dir}
    install -d -o ${user} -g ${group} -m 0750 ${dir}/memories

    ${configMerge} ${nixJson} ${dir}/config.yaml
    chown ${user}:${group} ${dir}/config.yaml
    chmod 0640 ${dir}/config.yaml

    install -o ${user} -g ${group} -m 0640 ${soulFile} ${dir}/SOUL.md
    ${lib.concatStrings memoryFiles}

    # .env: concatenated from the agenix-decrypted files this profile names,
    # plus any plain (non-secret) KEY=value pairs. Written via a temp file so a
    # half-written .env is never visible to a starting agent, and 0600 because
    # it holds provider keys. A missing/unreadable secret is logged and skipped
    # rather than fatal — agenix fails a single secret softly, and taking the
    # whole activation down with it would be worse than one profile without a
    # key (which hermes-config-check does not gate on, because `model` is set).
    tmpenv="$(mktemp)"
    chmod 0600 "$tmpenv"
    ${lib.concatMapStringsSep "\n" (f: ''
        if [ -r ${lib.escapeShellArg f} ]; then
          cat ${lib.escapeShellArg f} >> "$tmpenv"
          printf '\n' >> "$tmpenv"
        else
          echo "hermes-profiles: ${name}: ${f} unreadable, skipping" >&2
        fi
      '')
      profile.environmentFiles}
    ${lib.concatStringsSep "\n    " envLines}
    install -o ${user} -g ${group} -m 0600 "$tmpenv" ${dir}/.env
    rm -f "$tmpenv"
  '';

  # Every path the agent must not be able to rewrite: its own model/toolset
  # config and its own system prompt, per profile. The default profile's two
  # equivalents are bound by the host config (they are upstream's files, at
  # $HERMES_HOME/config.yaml and $HERMES_HOME/SOUL.md).
  readOnlyPaths =
    lib.concatMap (name: [
      "${profileDir name}/config.yaml"
      "${profileDir name}/SOUL.md"
    ])
    (lib.attrNames cfg.profiles);

  # Every config.yaml on the host, primary profile first. The check gates
  # hermes-agent, so the default profile's file — the one the gateway itself
  # loads — is checked before any secondary one.
  checkedConfigs =
    ["${hermesHome}/config.yaml"]
    ++ map (name: "${profileDir name}/config.yaml") (lib.attrNames cfg.profiles);

  profileType = lib.types.submodule ({name, ...}: {
    options = {
      settings = lib.mkOption {
        type = yamlFormat.type;
        default = {};
        description = ''
          This profile's `config.yaml`, deep-merged into whatever is on disk
          with Nix winning per key. `model` is effectively required: Hermes has
          no env fallback for it, and hermes-config-check refuses to let the
          agent start without one.
        '';
      };

      soul = lib.mkOption {
        type = lib.types.either lib.types.path lib.types.lines;
        description = "This profile's SOUL.md — its system prompt.";
      };

      memories = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.lines);
        default = {};
        example = lib.literalExpression ''{ "USER.md" = ./user.md; }'';
        description = ''
          Files installed under `<profile>/memories/`. Hermes treats
          `memories/USER.md` and `memories/MEMORY.md` as part of the agent's
          identity, alongside SOUL.md. Keys are paths relative to `memories/`.
        '';
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Runtime paths (agenix, not Nix path literals — a path literal would
          copy the secret into the world-readable store) whose contents are
          concatenated into this profile's `.env`. A named profile resolves its
          provider credentials from its OWN .env, so this is what gives each
          profile its own key.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Non-secret KEY=value pairs appended to this profile's .env.";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable note; documentation only.";
      };
    };
  });
in {
  options.homelab.hermesProfiles = {
    profiles = lib.mkOption {
      type = lib.types.attrsOf profileType;
      default = {};
      description = ''
        Secondary Hermes profiles, rendered under
        `''${services.hermes-agent.stateDir}/.hermes/profiles/<name>/`. The
        DEFAULT profile is not declared here — it is the upstream module's own
        home, configured with `services.hermes-agent.{settings,hermesHomeFiles}`.
      '';
    };

    configCheckPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = checkedConfigs;
      description = "Every config.yaml hermes-config-check validates (read-only).";
    };
  };

  config = lib.mkIf (cfg.profiles != {}) {
    # Ordered after `users` (the account must exist to chown to) and after
    # agenix's setupSecrets (the .env sources must be decrypted). Both are the
    # same anchors upstream's own hermes-agent-setup script uses.
    system.activationScripts.hermes-profiles =
      lib.stringAfter
      (["users"] ++ lib.optional (config.system.activationScripts ? setupSecrets) "setupSecrets")
      ''
        set -u
        install -d -o ${user} -g ${group} -m 0750 ${hermesHome}/profiles
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderProfile cfg.profiles)}
      '';

    # Bind every rendered config/SOUL read-only inside the agent's namespace.
    # `unitOption` concatenates list definitions across modules, so this MERGES
    # with the host's own ReadOnlyPaths rather than replacing them.
    systemd.services.hermes-agent.serviceConfig.ReadOnlyPaths = readOnlyPaths;

    # The gate. `hermes-agent` requires it, so an unparseable config.yaml —
    # in ANY profile — blocks the start instead of silently demoting that
    # agent to built-in defaults.
    systemd.services.hermes-config-check = {
      description = "Validate + repair every hermes config.yaml before the agent starts";
      after = ["agenix.target"];
      wants = ["agenix.target"];
      before = ["hermes-agent.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = group;
        ExecStart = map (p: "${configCheck} ${p}") checkedConfigs;
      };
    };

    systemd.services.hermes-agent = {
      requires = ["hermes-config-check.service"];
      after = ["hermes-config-check.service"];
    };
  };
}
