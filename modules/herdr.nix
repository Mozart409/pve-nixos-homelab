{
  config,
  lib,
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
    # ctrl+space prefix (tmux-style leader key) with `ctrl+alt` family as
    # aliases. herdr bindings are written "prefix+<key>", NOT a literal
    # "ctrl+space+<key>" chord — `herdr config check` rejects the latter as an
    # invalid keybinding (space is not a modifier it composes with ctrl in a
    # single chord; prefix is its own leader-key mechanism). The ctrl+alt
    # family is the only chord set every major terminal and desktop leave free
    # (unlike ctrl+alt+arrows = GNOME workspaces/Ghostty/Konsole, or
    # ctrl+alt+t = "launch terminal"), so these survive the outer terminal and
    # land in herdr.
    prefix = "ctrl+space"
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
    # workspace_picker (herdr's config key; the docs prose calls it "workspace
    # navigation") is bound to plain "prefix+w" by default and needs no entry
    # here to work — but the sequential ctrl+space-then-w chord was observed
    # not firing on this host (herdr-client.log shows recurring "flushing lone
    # escape after input timeout" warnings, i.e. this terminal's raw-input
    # parsing is timing-sensitive around chords) while other prefix chords on
    # the same leader worked fine. ctrl+alt+w is a single simultaneous chord
    # like the focus_pane/tab bindings above, sidestepping that timing path
    # entirely as a reliable fallback.
    workspace_picker = ["prefix+w", "ctrl+alt+w"]

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
  # A failed install is NON-FATAL by design, and one failure mode is STRUCTURAL:
  # `herdr plugin install` needs a **running herdr server** (it registers the
  # plugin with it over the XDG_RUNTIME_DIR socket), and at boot there is none.
  # It fails with a bare `Error: Os { code: 2, kind: NotFound, message: "No such
  # file or directory" }` — that is the missing socket, NOT a missing binary or a
  # bad plugin, so do not go hunting for a PATH problem. `herdr integration
  # install` above only writes files, which is why it succeeds in the same run.
  #
  # Consequence: a genuinely new plugin cannot be installed headlessly. Install
  # it once from a terminal with herdr running, and every later activation takes
  # the "already installed" branch. The three below were bootstrapped that way.
  #
  # These installs also reach out to GitHub and run third-party manifest build
  # steps, so they are the least reliable part of this module — and because
  # herdr-setup is a *user* unit that NixOS restarts during activation, letting
  # one abort the script fails the unit, which fails `colmena apply` for the
  # whole host. That is a bad trade: a flaky third-party plugin should never
  # block a system deploy. So each install is attempted independently, failures
  # are collected in `failed`, and the script logs a loud WARNING and exits 0.
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

  # Unlike `just` (modules/just-completions.nix), herdrPkg's output has no
  # prebuilt `share/zsh/site-functions/_herdr` — `herdr completion zsh` prints
  # the script to stdout at runtime instead. So it's generated at build time by
  # actually running the real binary (pure: no network/server, just clap
  # printing static text), the same way many Rust CLIs wire this up in
  # nixpkgs. Only installed where zsh completion is actually wired up
  # (programs.zsh.enableCompletion in modules/common.nix puts
  # /run/current-system/sw/share/zsh/site-functions on fpath) — a completion
  # file is dead weight on a host with no zsh to load it.
  herdrZshCompletion =
    pkgs.runCommand "herdr-zsh-completions" {}
    ''
      mkdir -p $out/share/zsh/site-functions
      ${herdrPkg}/bin/herdr completion zsh > $out/share/zsh/site-functions/_herdr
    '';

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

  # herdr-spreader starter layout (tmuxinator-for-herdr). Workspace names are
  # derived from the final directory component, so changing a root cannot leave
  # a stale label behind. Nix owns this generated file; change the workspace
  # roots below rather than editing the runtime copy. Apply it with:
  #   herdr plugin action invoke herdr-spreader.apply
  #
  # One workspace per repo checkout, each with the same three tabs in a fixed
  # order so prefix+1..3 means the same thing everywhere: 1 and 2 are bare
  # shells, 3 is lazygit. `homelab` (this repo) is the focused workspace,
  # since it is the one that deploys the others.
  #
  # Deliberately does NOT auto-launch claude/opencode: an agent tab per
  # workspace idled at ~4 spreader workspaces was too much resident memory to
  # keep running unused. Launch an agent by hand when you actually need one
  # (prefix+c for a new tab, then `claude` or `opencode`) — `session` above
  # (`resume_agents_on_restore`) still reattaches any agent pane you did start
  # into its native conversation after a herdr server restart; it just has
  # nothing to reattach until you start one.
  #
  # Roots must exist — spreader cannot cd into a missing directory, and that tab
  # comes up in the home dir (or not at all) instead.
  spreaderWorkspaces = [
    {
      root = "~/code/pve-nixos-homelab";
      focus = true;
    }
    {root = "~/code/nixos-ventara-ai";}
    {root = "~/code/obsidian-kb";}
    {root = "~/code/rust/surrealdb-engram";}
    {root = "~/code/homelab-mcp-servers";}
  ];

  spreaderTabList = [
    {
      label = "shell-1";
      command = "zsh";
    }
    {
      label = "shell-2";
      command = "zsh";
    }
    {
      label = "lazygit";
      command = "lazygit";
    }
  ];

  # Built as an explicit list of already-indented lines, NOT a ''-string with
  # ${} interpolation of another multi-line ''-string. Nix computes a ''
  # string's common-indentation strip once, statically, from its literal
  # source lines — it ignores lines that are pure whitespace when finding the
  # minimum. Splicing a conditional single-line interpolation (the old
  # `focus: true\n`) in front of a separately-stripped multi-line value
  # (the old `spreaderTabs`) made that minimum computation diverge between the
  # focus and non-focus branches, so `tabs:` landed at column 0 (a sibling of
  # top-level `workspaces:`, breaking the YAML) only for the focus workspace.
  # Plain string concatenation of literal, pre-indented lines has no such
  # static/dynamic mismatch to trip over.
  spreaderTabsLines = tabs:
    ["  tabs:"]
    ++ builtins.concatMap (t: [
      "    - label: ${t.label}"
      "      panes:"
      "        - command: ${t.command}"
    ])
    tabs;

  spreaderWorkspace = workspace: let
    tabs = workspace.tabs or spreaderTabList;
    lines =
      [
        "- name: ${builtins.baseNameOf (lib.removeSuffix "/" workspace.root)}"
        "  root: ${workspace.root}"
      ]
      ++ lib.optional (workspace.focus or false) "  focus: true"
      ++ spreaderTabsLines tabs;
  in
    builtins.concatStringsSep "\n" lines + "\n";

  # Spreader always calls `workspace create`; it does not skip a workspace that
  # is already present. Keep one fragment per workspace so setup can omit roots
  # that are currently visible in the running herdr session before writing the
  # config consumed by `herdr-spreader.apply`.
  spreaderWorkspaceFragments =
    map (workspace: {
      root = lib.replaceStrings ["~"] [home] workspace.root;
      file = pkgs.writeText "herdr-spreader-${builtins.baseNameOf (lib.removeSuffix "/" workspace.root)}" (spreaderWorkspace workspace);
    })
    spreaderWorkspaces;

  spreaderLayoutScript =
    "printf '%s\\n' 'workspaces:' > \"$spreader_layout_tmp\"\n"
    + builtins.concatStringsSep "\n" (map (workspace: ''
        if [ -z "${"$spreader_snapshot"}" ] || printf '%s' "${"$spreader_snapshot"}" | ${pkgs.jq}/bin/jq -e --arg root "${workspace.root}" \
          '[.result.snapshot.panes[] | select((.cwd == $root) or (.foreground_cwd == $root))] | length == 0' >/dev/null; then
          cat ${workspace.file} >> "$spreader_layout_tmp"
          echo "herdr-setup: including workspace ${workspace.root}"
        else
          echo "herdr-setup: skipping already-open workspace ${workspace.root}"
        fi
      '')
      spreaderWorkspaceFragments);

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
      # Write the generated layout on every activation so folder-derived names
      # stay current when a workspace root changes. Spreader itself is not
      # idempotent, so omit roots that already have a live pane in herdr.
      spreader_config_dir="${home}/.config/herdr/plugins/config/herdr-spreader"
      mkdir -p "$spreader_config_dir"
      spreader_layout_tmp="$(mktemp "$spreader_config_dir/config.yaml.XXXXXX")"
      if spreader_snapshot="$(${herdrPkg}/bin/herdr api snapshot 2>/dev/null)"; then
        echo "herdr-setup: checking open workspaces before generating spreader layout"
      else
        spreader_snapshot=""
        echo "herdr-setup: herdr server unavailable; including all spreader workspaces"
      fi
      ${spreaderLayoutScript}
      install -m0644 "$spreader_layout_tmp" "$spreader_config_dir/config.yaml"
      rm -f "$spreader_layout_tmp"

      # Deliberately exit 0 even here: see the plugins comment above. The deploy
      # stays green and this warning is the only signal, so make it findable.
      if [ -n "$failed" ]; then
        echo "herdr-setup: WARNING these plugins are NOT installed:$failed" >&2
        echo "herdr-setup: retry with 'systemctl --user restart herdr-setup', inspect with 'herdr plugin list'" >&2
      fi
    ''
  );
in {
  environment.systemPackages =
    [
      herdrPkg
      # Plugin build/runtime deps for the bootstrapped plugins:
      pkgs.cargo # herdr-spreader builds at install time
      pkgs.gcc # cargo links with `cc` — without it the build dies with "linker `cc` not found"
      pkgs.bun # window-title-sync event hooks run `bun sync-title.js`
      pkgs.worktrunk # worktrunk plugin shells out to the `wt` CLI
      pkgs.jq # automatic-rename's engine + shell hooks parse `herdr ... --json`
    ]
    ++ lib.optional config.programs.zsh.enable herdrZshCompletion;

  # herdr-automatic-rename's real-time half. The plugin's manifest hooks only
  # fire on herdr *events* (tab/pane create, close, focus), and herdr has no
  # "foreground command changed" event — so without this the tab name lags until
  # you touch something. This hook renames the instant a command starts.
  #
  # Lives here rather than in modules/common.nix's zsh block so it lands only on
  # hosts that actually import herdr; interactiveShellInit is a `lines` option,
  # so the two definitions merge instead of conflicting.
  #
  # `(N)` is zsh's nullglob qualifier, and it is load-bearing: the plugin's
  # install can fail (it needs a running herdr server — see the plugins comment
  # above), and without `(N)` an unmatched glob makes zsh error on *every*
  # interactive shell start. With it, the loop body is simply skipped.
  programs.zsh.interactiveShellInit = ''
    # herdr-automatic-rename: rename the tab as each command starts. Self-locates
    # the engine under whichever versioned dir herdr installed it to, and is a
    # no-op outside a herdr pane.
    for _f in $HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.zsh(N); do
      source "$_f"
      break
    done
    unset _f
  '';

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
