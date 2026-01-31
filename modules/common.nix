{
  config,
  lib,
  pkgs,
  ...
}: {
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
      ld = "lazydocker";
      sys = "systemctl status";
      syr = "systemctl restart";
      k = "kubectl";
      flk = "cd /etc/nixos";
      dps = "docker compose ps";
      dup = "docker compose up -d --build --remove-orphans";
      dwn = "docker compose down";
      pup = "podman-compose up -d";
      pwn = "podman-compose down";
      n = "nvim .";
      t = "tmux";
      opencode = "nix run github:anomalyco/opencode";
      zkdir = "cd ~/code/zettelkasten/";
    };
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

  # Common user configuration
  users.users.amadeus = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = ["wheel" "networkmanager"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"
    ];
  };

  # Enable sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # Common packages
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    tmux
    curl
    wget
    rsync
    iproute2
    iputils
    bind
    traceroute
  ];

  # Enable nix flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Trust the amadeus user for remote builds
  nix.settings.trusted-users = ["root" "amadeus"];

  # Networking basics - DHCP disabled, using static IPs per host
  networking.useDHCP = lib.mkDefault false;

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
