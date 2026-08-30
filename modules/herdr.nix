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

  # Shared opencode server: every opencode TUI process bundles its own full
  # embedded server (provider clients, plugin runtime, sqlite handles), and
  # each idle instance costs ~500MB resident. Session/project data lives in a
  # shared local DB independent of any particular server process (verified
  # against the server's own HTTP API: /project and /session already listed
  # entries from unrelated prior `opencode` runs on first query), so nothing
  # is lost by pointing every pane at one shared server instead of running N
  # independent embedded ones. See the `opencode` zsh function below.
  opencodeServerPort = 44096;

  # herdr — terminal workspace manager for AI coding agents (tmux/zellij-class).
  # moshi-hook detects it as a multiplexer, and herdr's own opencode integration
  # reports agent state back into the workspace UI.
  #
  # Nix owns config.toml outright (rewritten on every activation) rather than
  # merging: it is small, fully hand-authored, and has no runtime-written keys.
  # NB that means `herdr config set …` is NOT durable — change it here instead.
  # Runtime state herdr *does* own (session.json, logs) lives in sibling files
  # and is untouched. No plugins are installed by this module.
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
    focus_agent = "prefix+alt+1..9"
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
  environment.systemPackages =
    [
      herdrPkg
    ]
    ++ lib.optional config.programs.zsh.enable herdrZshCompletion;

  # Lives here rather than in modules/common.nix's zsh block so it lands only on
  # hosts that actually import herdr; interactiveShellInit is a `lines` option,
  # so the two definitions merge instead of conflicting.
  programs.zsh.interactiveShellInit = ''
    # Route interactive opencode launches/resumes through one shared server
    # (see opencodeServerPort's comment in modules/herdr.nix for why this is
    # safe) instead of each pane spawning its own embedded one. herdr's own
    # resume flow types `opencode --session <id>` into a real interactive
    # shell rather than exec'ing the binary directly (src/app/agent_resume.rs
    # in herdr's source), so this function is exactly as visible to herdr's
    # resume as it is to a manually-typed `opencode`. Only a bare launch or
    # the flag set herdr's resume plan actually uses is intercepted; anything
    # else (subcommands like `auth`/`run`/`models`, or flags `attach` doesn't
    # support) passes straight through to the real binary untouched.
    opencode() {
      case "$1" in
        ""|--session|-s|--continue|-c|--fork)
          if ! systemctl --user is-active --quiet opencode-server.service 2>/dev/null; then
            # `systemd-run --user` starts the transient unit as a child of the
            # systemd --user manager, NOT of this shell — so it does not
            # inherit AXON_GATEWAY_TOKEN/VENTARA_GATEWAY_TOKEN just because
            # interactiveShellInit (coding-harness.nix) exported them here.
            # Bare `--setenv=NAME` (no `=VALUE`) forwards this shell's current
            # value into the unit, and is a silent no-op when a var is unset
            # (e.g. VENTARA_GATEWAY_TOKEN on hosts without that key) — verified
            # empirically, not just per the systemd-run(1) NAME[=VALUE] syntax.
            # Without this the shared server's MCP clients silently authed
            # with an empty bearer token and every MCP call was rejected.
            systemd-run --user --unit=opencode-server --collect \
              --setenv=AXON_GATEWAY_TOKEN --setenv=VENTARA_GATEWAY_TOKEN \
              ${pkgs.opencode}/bin/opencode serve --port ${toString opencodeServerPort} --hostname 127.0.0.1 \
              >/dev/null 2>&1
            # A cold-boot start (server binary + plugin node_modules bootstrap)
            # has been observed taking ~15s end to end, well past a short poll
            # budget — so this waits up to 60s, and on genuine failure to come
            # up REFUSES to attach instead of racing an `opencode attach` against
            # a still-closed port (which fails with an opaque "Unable to
            # connect" from the opencode CLI itself, indistinguishable from a
            # real outage).
            local _oc_tries=0
            until ${pkgs.curl}/bin/curl -sS -m1 -o /dev/null "http://127.0.0.1:${toString opencodeServerPort}/doc" 2>/dev/null \
              || [ "$_oc_tries" -ge 240 ]; do
              sleep 0.25
              _oc_tries=$((_oc_tries + 1))
            done
            if [ "$_oc_tries" -ge 240 ]; then
              echo "opencode: shared server did not come up on 127.0.0.1:${toString opencodeServerPort} within 60s — check 'systemctl --user status opencode-server'" >&2
              return 1
            fi
          fi
          command opencode attach "http://127.0.0.1:${toString opencodeServerPort}" --dir "$PWD" "$@"
          ;;
        *)
          command opencode "$@"
          ;;
      esac
    }

    # herdr derives a space's label from its cwd exactly once, when the space is
    # created, and never re-derives it: on 0.8.2 a `cd` updates the pane's
    # tracked `cwd`/`foreground_cwd` while the space label stays put. So a space
    # created from $HOME reads "~" forever, even once its panes sit deep inside a
    # project. There is no config key for follow-the-cwd naming (`herdr
    # --default-config` offers only prompt_new_workspace_name and the manual
    # rename_workspace binding), so re-apply herdr's own rule from a chpwd hook.
    #
    # Nix owns the *mechanism*; the label itself stays herdr session state in
    # session.json, which is where it belongs -- it changes on every cd and is
    # deliberately not declared anywhere in this module.
    #
    # The name is the git worktree root's basename rather than plain ''${PWD:t},
    # so moving around inside a repo (hosts/, modules/, ...) keeps the space
    # named after the repo instead of flapping to the last subdirectory. Outside
    # a repo it falls back to herdr's own rule: basename of $PWD, `~` for $HOME.
    if [[ -n ''${HERDR_ENV:-} && -n ''${HERDR_WORKSPACE_ID:-} ]]; then
      autoload -Uz add-zsh-hook

      _herdr_rename_space_to_cwd() {
        local label root
        if root=$(command git rev-parse --show-toplevel 2>/dev/null) && [[ -n $root ]]; then
          label=''${root:t}
        elif [[ $PWD == $HOME ]]; then
          label='~'
        else
          label=''${PWD:t}
        fi

        # chpwd fires on every cd; only hit the socket when the resulting name
        # actually differs. Both calls are ~4ms, so this stays synchronous and
        # renames cannot land out of order.
        [[ $label == ''${_HERDR_SPACE_LABEL:-} ]] && return 0
        _HERDR_SPACE_LABEL=$label
        # NB HERDR_WORKSPACE_ID is the id injected when this pane was created;
        # a pane later moved to another space keeps the old one, so its cds
        # would rename the space it came from until the shell is restarted.
        command herdr workspace rename "$HERDR_WORKSPACE_ID" "$label" >/dev/null 2>&1
      }

      add-zsh-hook chpwd _herdr_rename_space_to_cwd
      _herdr_rename_space_to_cwd
    fi
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
    description = "herdr config + agent integrations for ${user}";
    wantedBy = ["default.target"];
    # Both this and moshi-hook-setup write ~/.claude/settings.json. Each only
    # touches its own hook entries, but pin the order so the result is
    # reproducible rather than a boot-time race. After= on a unit that does not
    # exist is a no-op, so this stays valid if moshi-hook-user.nix is not imported.
    after = ["moshi-hook-setup.service"];
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
