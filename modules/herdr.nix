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
  # Nix owns config.toml outright (rewritten on every activation) rather than
  # merging: it is small, fully hand-authored, and has no runtime-written keys.
  # NB that means `herdr config set …` is NOT durable — change it here instead.
  # Runtime state herdr *does* own (plugins.json, the downloaded plugins under
  # plugins/github/, session.json, logs) lives in sibling files and is untouched.
  # Plugin *installs* are bootstrapped here but stay herdr-owned afterwards: the
  # setup script only installs a plugin when `herdr plugin list` shows it missing.
  configToml = pkgs.writeText "herdr-config.toml" ''
    onboarding = false

    [keys]
    # Stock tmux-style prefix defaults, plus the docs' vetted prefix-free
    # `ctrl+alt` family as aliases. The ctrl+alt family is the only chord set
    # every major terminal and desktop leave free (unlike ctrl+alt+arrows =
    # GNOME workspaces/Ghostty/Konsole, or ctrl+alt+t = "launch terminal"), so
    # these survive the outer terminal and land in herdr. Each action keeps the
    # prefix binding as the primary and the direct chord as a second binding.
    focus_pane_left = ["prefix+h", "ctrl+alt+h"]
    focus_pane_down = ["prefix+j", "ctrl+alt+j"]
    focus_pane_up = ["prefix+k", "ctrl+alt+k"]
    focus_pane_right = ["prefix+l", "ctrl+alt+l"]
    previous_tab = ["prefix+p", "ctrl+alt+["]
    next_tab = ["prefix+n", "ctrl+alt+]"]
    new_tab = ["prefix+c", "ctrl+alt+c"]
    split_vertical = ["prefix+v", "ctrl+alt+d"]
    split_horizontal = ["prefix+minus", "ctrl+alt+shift+d"]
    zoom = ["prefix+z", "ctrl+alt+z"]
    switch_tab = "prefix+1..9"

    # prefix+t opens a session-modal scratch terminal without touching the tab
    # layout (docs recipe). Exit the shell to close the popup and restore the view.
    [[keys.command]]
    key = "prefix+t"
    type = "popup"
    command = "exec \"${SHELL:-sh}\""
    description = "open scratch terminal"
    width = "80%"
    height = "80%"

    [session]
    # Resume Claude Code / opencode panes into their native conversation
    # sessions after a server restart. Only panes with a session ref from an
    # official integration resume; the rest restore as plain shells.
    resume_agents_on_restore = true

    [worktrees]
    # Root for `New worktree` sidebar checkouts: <dir>/<repo>/<branch-slug>.
    # Matches this repo's git-worktree workflow.
    directory = "~/.herdr/worktrees"

    [ui]
    show_agent_labels_on_pane_borders = true
    agent_panel_sort = "priority"

    # Create tabs immediately with generated names instead of prompting — this
    # host is agent-driven and a name prompt stalls an unattended session.
    prompt_new_tab_name = false

    [ui.sidebar.agents]
    # Richer agent rows: show the agent's live terminal title (Claude Code /
    # opencode paint progress there) under the state icon + workspace + tab.
    rows = [["state_icon", "workspace", "tab"], ["agent", "terminal_title_stripped"]]

    [ui.toast]
    delivery = "herdr"

    [theme]
    name = "dracula"
    auto_switch = false
  '';

  # Plugins provisioned by herdr-setup. `herdr plugin install <owner/repo> --yes`
  # clones from GitHub, runs the manifest build step (spreader builds with cargo),
  # and registers the plugin globally in plugins.json. Each install is guarded by
  # `herdr plugin list` so it runs once and is skipped on later activations.
  #
  # A failed install is NON-FATAL by design. These installs reach out to GitHub
  # and run third-party manifest build steps, so they are the least reliable part
  # of this module — and because herdr-setup is a *user* unit that NixOS restarts
  # during activation, letting one abort the script fails the unit, which fails
  # `colmena apply` for the whole host. That is a bad trade: a flaky third-party
  # plugin should never block a system deploy. So each install is attempted
  # independently, failures are collected in `failed`, and the script logs a loud
  # WARNING and still exits 0.
  #
  # The cost is that a persistently broken plugin is *quiet* — the deploy goes
  # green with the plugin missing. `herdr plugin list` is the check, and the
  # warning names every plugin that did not install. Restart=on-failure is kept
  # for the parts above that genuinely must succeed (config, integrations).
  plugins = [
    {
      # tmux `automatic-rename` for herdr: each tab is renamed to its foreground
      # process (`nvim`, `claude`) or the shell name at a bare prompt. A tab you
      # rename by hand opts out until `herdr plugin action invoke
      # herdr-automatic-rename.reset`. Pure bash + jq (jq comes from
      # modules/common.nix), so unlike spreader it has no build step.
      #
      # `prompt_new_tab_name = false` above is exactly what this plugin wants —
      # a name typed at that prompt counts as a hand rename and opts the tab out.
      #
      # Ships a second, independent feature: an `[N]` 1-9 jump-key prefix on
      # workspaces/tabs (`AUTO_INDEX`, on by default). Agent rows never get one
      # on herdr >= 0.7.5, which restricted agent names to
      # `^[a-z][a-z0-9_-]{0,31}$` — a bracketed number cannot match. That is also
      # moot under `agent_panel_sort = "priority"` above, which the plugin cannot
      # number either. Both are agent-row-only; tab naming is unaffected.
      #
      # Defaults need no config; to tune it, drop a config.sh at
      # ~/.config/herdr-automatic-rename/ (e.g. AUTO_INDEX=0 for bare names).
      id = "herdr-automatic-rename";
      source = "qu8n/herdr-automatic-rename";
      description = "rename each tab to its foreground process (tmux automatic-rename)";
    }
    {
      id = "herdr-spreader";
      source = "yuk1ty/herdr-spreader";
      description = "declarative workspace/tab/pane layouts (tmuxinator-style)";
    }
    {
      id = "rjyo.window-title-sync";
      source = "rjyo/herdr-window-title-sync";
      description = "sync outer terminal title to focused workspace/tab/agent";
    }
    {
      id = "worktrunk";
      source = "devashish2203/herdr-worktrunk";
      description = "git worktree switch/create/remove via the worktrunk CLI";
    }
  ];

  pluginInstallScript =
    builtins.concatStringsSep ""
    (map (p: ''
        if ${herdrPkg}/bin/herdr plugin list 2>/dev/null | grep -q "${p.id}"; then
          echo "herdr-setup: plugin ${p.id} already installed"
        else
          echo "herdr-setup: installing plugin ${p.id} (${p.source}) — ${p.description}"
          # `if cmd` keeps this out of `set -e`'s reach, so a failure is recorded
          # and the remaining plugins are still attempted.
          if ${herdrPkg}/bin/herdr plugin install ${p.source} --yes; then
            echo "herdr-setup: installed plugin ${p.id}"
          else
            echo "herdr-setup: WARNING failed to install plugin ${p.id} (${p.source})" >&2
            failed="$failed ${p.id}"
          fi
        fi
      '')
      plugins);

  # herdr-spreader starter layout (tmuxinator-for-herdr). Written to the plugin's
  # config dir only when absent, so user edits survive activations. Apply it with:
  #   herdr plugin action invoke herdr-spreader.apply
  spreaderLayout = pkgs.writeText "herdr-spreader-config.yaml" ''
    workspaces:
      - name: dev
        root: ~
        focus: true
        tabs:
          - label: shell
            panes:
              - command: zsh
          - label: git
            panes:
              - command: git status
  '';

  setup = pkgs.writeShellScript "herdr-setup-${user}" (
    ''
      set -eu

      # Names of plugins whose install failed this run; reported at the end.
      failed=""

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
    ''
    + pluginInstallScript
    + ''
      # Seed herdr-spreader's starter layout only when absent.
      spreader_config_dir="${home}/.config/herdr/plugins/config/herdr-spreader"
      mkdir -p "$spreader_config_dir"
      if [ ! -e "$spreader_config_dir/config.yaml" ]; then
        install -m0644 ${spreaderLayout} "$spreader_config_dir/config.yaml"
      fi

      # Deliberately exit 0 even here: see the plugins comment above. The deploy
      # stays green and this warning is the only signal, so make it findable.
      if [ -n "$failed" ]; then
        echo "herdr-setup: WARNING these plugins are NOT installed:$failed" >&2
        echo "herdr-setup: retry with 'systemctl --user restart herdr-setup', inspect with 'herdr plugin list'" >&2
      fi
    ''
  );
in {
  environment.systemPackages = [
    herdrPkg
    # Plugin build/runtime deps for the bootstrapped plugins:
    pkgs.cargo # herdr-spreader builds at install time
    pkgs.gcc # cargo links with `cc` — without it the build dies with "linker `cc` not found"
    pkgs.bun # window-title-sync event hooks run `bun sync-title.js`
    pkgs.worktrunk # worktrunk plugin shells out to the `wt` CLI
    pkgs.jq # automatic-rename's engine + shell hooks parse `herdr ... --json`
  ];

  # Start the user manager at boot so this runs without a login session.
  # types.bool merges equal definitions, so modules/moshi-hook-user.nix setting
  # the same thing is not a conflict.
  users.users.${user}.linger = true;

  # A **user** unit, not a system unit with User=amadeus, for two reasons:
  # ordering against moshi-hook-setup (below) is only expressible within the
  # same systemd manager, and herdr resolves its own socket via XDG_RUNTIME_DIR
  # the same way moshi-hook does.
  systemd.user.services.herdr-setup = {
    description = "herdr config + agent integrations + plugins for ${user}";
    wantedBy = ["default.target"];
    # Both this and moshi-hook-setup write ~/.claude/settings.json. Each only
    # touches its own hook entries, but pin the order so the result is
    # reproducible rather than a boot-time race. After= on a unit that does not
    # exist is a no-op, so this stays valid if moshi-hook-user.nix is not imported.
    after = ["moshi-hook-setup.service"];
    # Plugin installs no longer fail the unit (see the plugins comment above), so
    # this covers the parts that must succeed: writing config.toml and the
    # opencode/claude integrations. Those are idempotent, so retries are cheap.
    # A plugin that failed to install is retried on the next activation or on a
    # manual `systemctl --user restart herdr-setup`, since the `herdr plugin
    # list` guard re-attempts anything still missing.
    startLimitBurst = 5;
    startLimitIntervalSec = 600;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setup;
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
