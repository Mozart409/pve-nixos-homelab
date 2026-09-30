# CLI/TUI skins for the hermes profiles: high-contrast grey text on a dark
# terminal, one accent colour per profile so you can tell at a glance which
# agent you are talking to. Schema: hermes_cli/skin_engine.py (SkinConfig);
# docs: https://hermes-agent.nousresearch.com/docs/user-guide/features/skins
#
# Every colour key the built-in `default` skin sets is set here too, so
# nothing falls back to its gold. Dark-only on purpose: the host pins
# HERMES_TUI_THEME=dark (configuration.nix), because the TUI's background
# detection picked the default skin's LIGHT palette (dark brown #5C4718 ink)
# on a dark terminal, which was what made tool/skill names unreadable.
let
  # Shared greys, tuned for a ~#16161e background.
  #   text  #EDEDED  ~15:1      dim   #A8A8A8  ~8:1 (the old dim was ~2:1)
  #   rule  #6E6E6E  borders/separators only, never text
  mkColors = accent: {
    banner_border = accent.dark;
    banner_title = accent.main;
    banner_accent = accent.main;
    banner_dim = "#A8A8A8";
    banner_text = "#EDEDED";
    ui_accent = accent.main;
    ui_label = accent.light;
    ui_ok = "#5FD787";
    ui_error = "#FF6B6B";
    ui_warn = "#FFB454";
    prompt = "#EDEDED";
    input_rule = accent.dark;
    response_border = accent.main;
    status_bar_bg = "#23232E";
    status_bar_text = "#D0D0D0";
    status_bar_strong = accent.main;
    status_bar_dim = "#9A9A9A";
    status_bar_good = "#5FD787";
    status_bar_warn = "#FFB454";
    status_bar_bad = "#FF8C42";
    status_bar_critical = "#FF6B6B";
    session_label = accent.light;
    session_border = "#6E6E6E";
    completion_menu_bg = "#23232E";
    completion_menu_current_bg = "#3A3A4A";
    selection_bg = "#3A3A4A";
    shell_dollar = accent.main;
    voice_status_bg = "#23232E";
  };

  mkBranding = {
    who,
    symbol,
    goodbye,
  }: {
    agent_name = who;
    welcome = "${who} here. Type your message or /help for commands.";
    inherit goodbye;
    response_label = " ${symbol} ${who} ";
    prompt_symbol = symbol;
    help_header = "(${symbol}) Available Commands";
  };

  # Compact layout: the TUI falls back to the stock HERMES-AGENT art when
  # banner_logo is empty, so the top banner is a single header line instead,
  # and the name lives in the panel as part of the hero. The TUI parser
  # (parseRichMarkup) turns every [colour]…[/] tag into its own line, so
  # each line carries exactly one tag.
  eveLogo = ''
    [bold #FF79C6]✦ eve · personal assistant[/]
  '';
  eveHero = ''
    [#FFB3DF]     ▄[/]
    [#FF9BD2]    ███[/]
    [#FF79C6]  ▀█████▀[/]
    [#FF9BD2]    ███[/]
    [#FFB3DF]     ▀[/]

    [bold #FF79C6]█▀▀ █ █ █▀▀[/]
    [bold #E060AE]██▄ ▀▄▀ ██▄[/]
  '';
  heimdallLogo = ''
    [bold #7DCFFF]◉ heimdall · homelab watch[/]
  '';
  heimdallHero = ''
    [#B8E6FF]           █   █   █[/]
    [#9ADAFF]            █  █  █[/]
    [#7DCFFF]             █ █ █[/]
    [#5AB4E6]              ███[/]
    [#5AB4E6]               █[/]
    [#3D8FBF]               █[/]

    [bold #7DCFFF]█ █ █▀▀ █ █▀▄▀█ █▀▄ ▄▀█ █   █[/]
    [bold #5AB4E6]█▀█ ██▄ █ █ ▀ █ █▄▀ █▀█ █▄▄ █▄▄[/]
  '';
  switchboardLogo = ''
    [bold #FFFFFF]██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗[/]
    [bold #EDEDED]██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝[/]
    [bold #D6D6D6]███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗[/]
    [bold #D6D6D6]██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║[/]
    [bold #B5B5B5]██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║[/]
    [bold #8A8A8A]╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝[/]
  '';
in {
  eve = {
    name = "eve";
    description = "Eve: grey on dark, rose accent";
    colors = mkColors {
      main = "#FF79C6";
      light = "#FFB3DF";
      dark = "#A8457F";
    };
    branding = mkBranding {
      who = "Eve";
      symbol = "✦";
      goodbye = "Bye for now ✦";
    };
    tool_prefix = "│";
    spinner = {
      waiting_faces = ["(✦)" "(✧)" "(⋆)"];
      thinking_faces = ["(✦)" "(✧)" "(⋆)" "(·)"];
      thinking_verbs = [
        "remembering"
        "looking it up"
        "taking notes"
        "checking the calendar"
        "reading the mail"
        "thinking it over"
      ];
    };
    banner_logo = eveLogo;
    banner_hero = eveHero;
  };

  heimdall = {
    name = "heimdall";
    description = "Heimdall: grey on dark, ice-blue accent";
    colors = mkColors {
      main = "#7DCFFF";
      light = "#B8E6FF";
      dark = "#3D8FBF";
    };
    branding = mkBranding {
      who = "Heimdall";
      symbol = "◉";
      goodbye = "Watch ends ◉";
    };
    tool_prefix = "│";
    spinner = {
      waiting_faces = ["(◉)" "(◎)" "(○)"];
      thinking_faces = ["(◉)" "(◎)" "(⌁)" "(○)"];
      thinking_verbs = [
        "watching"
        "scanning the logs"
        "querying prometheus"
        "listening"
        "reading the signs"
        "standing guard"
      ];
    };
    banner_logo = heimdallLogo;
    banner_hero = heimdallHero;
  };

  # The switchboard. Neutral on purpose: no accent, so it never gets mistaken
  # for one of the two profiles that actually do work.
  switchboard = {
    name = "switchboard";
    description = "Default profile: plain high-contrast greys";
    colors = mkColors {
      main = "#EDEDED";
      light = "#D0D0D0";
      dark = "#8A8A8A";
    };
    branding = mkBranding {
      who = "Hermes";
      symbol = "❯";
      goodbye = "Goodbye.";
    };
    tool_prefix = "│";
    banner_logo = switchboardLogo;
  };
}
