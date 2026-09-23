{
  config,
  lib,
  pkgs,
  ...
}: let
  hermesCfg = config.services.hermes-agent;
  hermesHome = "${hermesCfg.stateDir}/.hermes";

  # Every Hermes home on this host: the default profile ($HERMES_HOME itself)
  # plus each secondary profile under profiles/.
  profileHomes =
    [hermesHome]
    ++ map (name: "${hermesHome}/profiles/${name}")
    (lib.attrNames config.homelab.hermesProfiles.profiles);

  # ── Why this is stamped per (home, version) rather than run every boot ─────
  # `moshi-hook install` REWRITES $HERMES_HOME/config.yaml in place to register
  # its plugin, and it is NOT safe to rerun against a file another writer has
  # reformatted — despite upstream calling it idempotent.
  #
  # Two writers touch that file with INCOMPATIBLE list styles: the Nix config
  # merge re-dumps the whole document via PyYAML at 2-space sequence indent
  # (`  - moshi-hooks`), while `install` writes and matches its own 4-space
  # style. Neither recognises the other's form, so running `install` on a file
  # the merge just normalised makes it INSERT a duplicate 4-space item directly
  # under `enabled:`, above the existing 2-space one. Two sequence items at
  # different depths is unparseable YAML — and Hermes fails OPEN on a parse
  # error (gateway/run.py's _load_gateway_config substitutes an empty dict),
  # silently discarding every override including `model`. See AGENTS.md §6.
  #
  # Running `install` only once per (home, moshi-hook version) leaves a SINGLE
  # steady-state writer — the Nix merge — with the registration kept declarative
  # via `plugins.enabled = ["moshi-hooks"]` in the shared settings. A version
  # bump re-runs it in every home and re-triggers the corruption once;
  # hermes-config-check repairs it before the agent starts, so the deploy still
  # succeeds. A "repaired mixed-indent" line in that unit's journal after a bump
  # is the guard working, not a new bug.
  #
  # The stamp lives inside each home, so a state-dir wipe re-runs it there.
  installProfiles = pkgs.writeShellScript "hermes-moshi-profiles" ''
    set -u
    moshi=${pkgs.moshi-hook}/bin/moshi-hook

    for home in ${lib.escapeShellArgs profileHomes}; do
      stamp="$home/.moshi-hook-installed-${pkgs.moshi-hook.version}"
      if [ -e "$stamp" ]; then
        echo "hermes-moshi-profiles: $home already registered for v${pkgs.moshi-hook.version}; skipping (would rewrite config.yaml)"
        continue
      fi
      if [ ! -d "$home" ]; then
        echo "hermes-moshi-profiles: $home does not exist yet, skipping" >&2
        continue
      fi
      # Both are set because it is unverified which one moshi-hook resolves the
      # Hermes home from: the CLI documents $HERMES_HOME, but the target it
      # actually rewrote on the previous host was $HOME/.hermes/config.yaml.
      # Pointing both at the same directory makes either resolution correct.
      if HOME="$home" HERMES_HOME="$home" "$moshi" install; then
        touch "$stamp"
        echo "hermes-moshi-profiles: registered moshi-hooks in $home"
      else
        echo "hermes-moshi-profiles: install failed for $home" >&2
      fi
    done
  '';
in {
  # Pairing itself is per HOST, not per profile, and lives in
  # modules/moshi-hook-user.nix — one daemon in the hermes user's own systemd
  # manager (which is what `linger = true` on the account is for), plus the
  # $HOME-scoped hook wiring for Claude Code and opencode. This unit only does
  # the Hermes-side plugin registration, which is the part that is per-profile
  # and the part that can corrupt a config.yaml.
  systemd.services.hermes-moshi-profiles = {
    description = "Register the moshi-hooks plugin in every hermes profile home";
    wantedBy = ["multi-user.target"];
    after = ["agenix.target"];
    wants = ["agenix.target"];
    # Ordered BEFORE the config gate so a rewrite this unit causes is repaired
    # in the same boot, and before the agent that would otherwise load it.
    before = ["hermes-config-check.service" "hermes-agent.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = hermesCfg.user;
      Group = hermesCfg.group;
      ExecStart = installProfiles;
    };
  };

  # `RemainAfterExit` means the gate only ever runs once per boot, so a
  # mid-deploy restart of THIS unit (e.g. on a moshi-hook version bump, long
  # after the gate went active at boot) would rewrite config.yaml with nothing
  # left to repair it — the damage then surfacing on the NEXT deploy, inside the
  # activation script, where no unit ordering can prevent it. `partOf`
  # propagates the restart so the repair always follows a rewrite.
  systemd.services.hermes-config-check.partOf = ["hermes-moshi-profiles.service"];
}
