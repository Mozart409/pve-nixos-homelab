{
  pkgs,
  herdr,
  ...
}: let
  user = "amadeus";
  home = "/home/amadeus";

  herdrPkg = herdr.packages.${pkgs.stdenv.hostPlatform.system}.herdr;

  # herdr — terminal workspace manager for AI coding agents (tmux/zellij-class).
  # moshi-hook detects it as a multiplexer, and herdr's own opencode integration
  # reports agent state back into the workspace UI.
  #
  # Ported verbatim from the hand-built reference host, whose ~/.config/herdr/
  # config.toml this reproduces. Nix owns this file outright (rewritten on every
  # activation) rather than merging: it is small, fully hand-authored, and has no
  # runtime-written keys. NB that means `herdr config set …` is NOT durable —
  # change it here instead. Runtime state herdr *does* own (plugins.json, the
  # downloaded plugins under plugins/github/, session.json, logs) lives in
  # sibling files and is untouched.
  configToml = pkgs.writeText "herdr-config.toml" ''
    onboarding = false

    [ui]
    show_agent_labels_on_pane_borders = true
    agent_panel_sort = "priority"

    [ui.toast]
    delivery = "herdr"

    [theme]
    name = "dracula"
    auto_switch = false
  '';

  setup = pkgs.writeShellScript "herdr-setup-${user}" ''
    set -eu
    install -Dm0644 ${configToml} "${home}/.config/herdr/config.toml"

    # opencode: writes ~/.config/opencode/plugins/herdr-agent-state.js (a
    # standalone plugin file, auto-loaded from that dir).
    ${herdrPkg}/bin/herdr integration install opencode

    # `herdr integration install claude` hard-fails with "claude directory not
    # found … install claude code first" when ~/.claude is absent, which it is on
    # a freshly provisioned host until Claude Code is first launched. Create it
    # so the integration installs declaratively instead of needing a manual run.
    mkdir -p "${home}/.claude"

    # claude: writes ~/.claude/hooks/herdr-agent-state.sh AND registers hook
    # entries in ~/.claude/settings.json — a .sh in hooks/ is inert on its own,
    # Claude Code only fires hooks listed in settings.json.
    #
    # That is the same file `moshi-hook install` writes. Both tools do targeted
    # add/remove of *their own* entries (herdr's strings: "ensured claude
    # settings at", "removed herdr claude hook entries from"), so they coexist —
    # but only if neither rewrites the file wholesale, so ordering is pinned
    # below and both hook sets must be re-verified after deploy.
    ${herdrPkg}/bin/herdr integration install claude
  '';
in {
  environment.systemPackages = [herdrPkg];

  # Start the user manager at boot so this runs without a login session.
  # types.bool merges equal definitions, so modules/moshi-hook-user.nix setting
  # the same thing is not a conflict.
  users.users.${user}.linger = true;

  # A **user** unit, not a system unit with User=amadeus, for two reasons:
  # ordering against moshi-hook-setup (below) is only expressible within the
  # same systemd manager, and herdr resolves its own socket via XDG_RUNTIME_DIR
  # the same way moshi-hook does.
  systemd.user.services.herdr-setup = {
    description = "herdr config + agent integrations for ${user}";
    wantedBy = ["default.target"];
    # Both this and moshi-hook-setup write ~/.claude/settings.json. Each only
    # touches its own hook entries, but pin the order so the result is
    # reproducible rather than a boot-time race. After= on a unit that does not
    # exist is a no-op, so this stays valid if moshi-hook-user.nix is not imported.
    after = ["moshi-hook-setup.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setup;
    };
  };
}
