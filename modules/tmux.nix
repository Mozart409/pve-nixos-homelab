{
  config,
  lib,
  pkgs,
  ...
}: {
  # tmux config mirroring nixos-wotan (modules/home-manager/packages/tmux.nix)
  # but with the tokyo-night theme swapped for catppuccin (frappe flavor).
  # Shell helpers that pair with it live in modules/common.nix:
  #   t <name>  attach-or-create a tmux session named <name>
  #   tk        kill the current tmux session (closes every window in it)
  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    extraConfig = ''
      set-option -sa terminal-overrides ",xterm*:Tc"
      set -g mouse on
      set -g renumber-windows on
      set-option -g allow-passthrough on

      unbind C-b
      set -g prefix C-Space
      bind C-Space send-prefix

      # Shift arrow to switch windows
      bind -n S-Left previous-window
      bind -n S-Right next-window

      # Vim style pane selection
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      set-window-option -g mode-keys vi

      # keybindings
      bind-key -T copy-mode-vi v send-keys -X begin-selection
      bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
      bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel

      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"

      # Fast "I'm done here": prefix + X kills the whole session (with confirm).
      bind X confirm-before -p "kill session '#S'? (y/n)" kill-session

      # Catppuccin theme (frappe flavor), distinct from nixos-wotan's tokyo-night.
      set -g @catppuccin_flavour 'frappe'
      set -g @catppuccin_window_status_style 'rounded'

      # Auto-setup: 3 windows, first runs nvim
      set-hook -g session-created 'new-window ; new-window ; select-window -t :1 ; send-keys "nvim ." Enter'
    '';
    plugins = with pkgs; [
      tmuxPlugins.yank
      tmuxPlugins.urlview
      tmuxPlugins.sensible
      tmuxPlugins.catppuccin
      tmuxPlugins.tmux-floax
      tmuxPlugins.mode-indicator
    ];
  };
}
