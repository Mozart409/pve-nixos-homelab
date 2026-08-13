{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./nix-gc.nix
    ./homelab-users.nix
    ./just-completions.nix
  ];

  # Timezone configuration
  time.timeZone = "Europe/Berlin";

  # Locale and keyboard settings
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };

  # Console keymap
  console = {
    font = "Lat2-Terminus16";
    keyMap = "de";
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    autosuggestions.enable = true;
    histSize = 5000;
    histFile = "$HOME/.zsh_history";
    setOptions = [
      "HIST_IGNORE_SPACE"
      "EXTENDED_HISTORY"
      "HIST_IGNORE_DUPS"
      "HIST_SAVE_NO_DUPS"
      "SHARE_HISTORY"
      "HIST_EXPIRE_DUPS_FIRST"
    ];
    shellAliases = {
      l = "ls -lah";
      lg = "lazygit";
      sys = "systemctl status";
      syr = "systemctl restart";
      k = "kubectl";
      flk = "cd /etc/nixos";
      # Container aliases are podman-only; modules/podman.nix sets
      # dockerCompat = false, so there is no `docker` binary to fall back on.
      # The d* names are kept for muscle memory but run podman-compose.
      dps = "podman-compose ps";
      dup = "podman-compose up -d --build --remove-orphans";
      dwn = "podman-compose down";
      pps = "podman-compose ps";
      pup = "podman-compose up -d";
      pwn = "podman-compose down";
      n = "nvim .";
      zkdir = "cd ~/code/zettelkasten/";
    };
    interactiveShellInit = ''
      # `t <name>`: attach-or-create a tmux session named <name> (defaults to the
      # current directory name). From inside tmux it switches to the session,
      # creating it if needed. Pairs with the tmux config in modules/tmux.nix.
      t() {
        local name="''${1:-''${PWD##*/}}"
        if [[ -n "''${TMUX:-}" ]]; then
          tmux switch-client -t "$name" 2>/dev/null || tmux new-session -s "$name"
        elif tmux has-session -t "$name" 2>/dev/null; then
          tmux attach-session -t "$name"
        else
          tmux new-session -s "$name"
        fi
      }

      # `tk`: kill the tmux session the shell is currently in, closing every
      # window in it (neovim, lazygit, ...). Only ever touches the current session.
      # Outside tmux, `tk <name>` kills that named session.
      tk() {
        if [[ -n "''${TMUX:-}" ]]; then
          tmux kill-session
        elif [[ -n "''${1:-}" ]]; then
          tmux kill-session -t "$1" 2>/dev/null
        fi
      }
    '';
    ohMyZsh = {
      enable = true;
      # theme = "fino";
      theme = "dogenpunk";
      plugins = [
        "git"
        "z"
      ];
    };
  };

  # Prevent zsh new user dialog by creating .zshrc
  system.userActivationScripts.zshrc = "touch .zshrc";

  # X11 keymap (if needed for any graphical applications)
  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Mosh (mobile shell) for roaming/high-latency phone access. It bootstraps over
  # SSH, then switches to its own UDP protocol. openFirewall = true opens the
  # mosh UDP range (60000-61000) on every interface. Connect via the host's
  # Tailscale name/IP and pick "mosh" in the client (Blink Shell / Termius on iOS).
  #
  # Opening the host firewall is NOT sufficient on its own, and neither is
  # trusting tailscale0: the tailnet ACL is a separate layer that drops traffic
  # before it ever reaches this firewall. The grants in the tailscale-acls repo
  # were TCP-only for a long time, so tcp:22 let the SSH bootstrap succeed and
  # mosh-server start and report a port, while every subsequent datagram was
  # dropped by Tailscale and the client died with "Timed out waiting for server"
  # — a failure that reads exactly like a host firewall problem but is not one.
  # Any host reachable by mosh needs udp:60000-61000 granted to the connecting
  # user in policy.hujson as well as the openFirewall below.
  #
  # This also covers `moshi-hook host setup` (Easy Pair SSH/Mosh) on hosts
  # running the Moshi daemon — the key it wants to add is already the "iPhone"
  # key below, so that command never needs to be run.
  programs.mosh = {
    enable = true;
    openFirewall = true;
  };

  # Common user configuration. Adding another person is one attribute here (or
  # in a host config) -- see modules/homelab-users.nix.
  homelab.users.amadeus = {
    isAdmin = true;
    extraGroups = ["networkmanager"];
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPJIxb+FNkiFtPB/9eUenHa1RCWLBI0ia7KN/nFIdGH iPhone"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH/HCRJuzlIbgcWk68ehApZl6kN+7PnKIgYSLRZ5IjzQ amadeus@Amadeuss-MacBook-Pro.local"
      # Colmena deploys launched from the `development` host. Its private half
      # is passphrase-protected and pinned with `IdentityAgent none` (see
      # hosts/development/configuration.nix), so the unattended agent sessions
      # running as amadeus on that host cannot use it without a human typing
      # the passphrase. Do not add an agent-forwarded or unencrypted copy of
      # this key anywhere — that silently removes the only real gate.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVzXv+1p2UmSUDBtTw5sSFnz7sY3q86Vb/8GVhKKxo4 amadeus@development-colmena"
    ];
  };

  # Enable sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # Common packages
  environment.systemPackages = with pkgs; [
    # keep-sorted start
    bind
    busybox
    curl
    fd
    file
    fzf
    ghostty.terminfo
    git
    gnused
    gzip
    htop
    iproute2
    iputils
    jq
    kitty.terminfo
    mtr
    pv
    ripgrep
    rsync
    tmux
    traceroute
    tree
    unzip
    vim
    wget
    yq
    zip
    # keep-sorted end
  ];

  # Enable nix flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Trust the amadeus user for remote builds
  nix.settings.trusted-users = ["root" "amadeus"];

  # Networking basics - DHCP disabled, using static IPs per host
  networking.useDHCP = lib.mkDefault false;
  networking.nameservers = lib.mkDefault ["192.168.2.145" "192.168.2.1"];
  networking.search = ["homelab.local"];

  # Enable QEMU guest agent (for Proxmox)
  services.qemuGuest.enable = true;

  # Ensure the qemu-guest-agent service starts on boot
  systemd.services.qemu-guest-agent = {
    wantedBy = ["multi-user.target"];
  };

  # Boot loader configuration is handled by disko module
  # See modules/disko-config.nix for partition and boot setup

  # System state version (don't change this after initial installation)
  system.stateVersion = "25.05";
}
