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
  ];

  # Enable nix flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Networking basics
  networking.useDHCP = lib.mkDefault true;

  # Enable QEMU guest agent (for Proxmox)
  services.qemuGuest.enable = true;

  # Boot loader configuration is handled by disko module
  # See modules/disko-config.nix for partition and boot setup

  # System state version (don't change this after initial installation)
  system.stateVersion = "25.05";
}
