{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../../modules/step-ca-trust.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # SD image settings (only used for initial image build)
  sdImage.compressImage = false;
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Boot configuration for Pi
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

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

  console = {
    font = "Lat2-Terminus16";
    keyMap = "de";
  };

  # Networking
  networking = {
    hostName = "homelab-rpi4-1";
    useDHCP = lib.mkForce true;
    useNetworkd = true;
    wireless.enable = false;
    firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };
  };

  # Disable WiFi and Bluetooth hardware
  boot.blacklistedKernelModules = ["brcmfmac" "brcmutil" "btbcm" "hci_uart"];

  # Hardware watchdog - auto-reboots if system freezes
  systemd.watchdog = {
    runtimeTime = "30s";
    rebootTime = "10m";
  };

  # CPU frequency scaling - balance power and performance
  powerManagement.cpuFreqGovernor = "ondemand";

  # Swap file for 2GB Pi 4 models (safe to have on 4GB+ too)
  swapDevices = [
    {
      device = "/swapfile";
      size = 2048; # 2GB
    }
  ];

  # SSH - baked in so you can connect immediately
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # User configuration
  users.users.amadeus = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = ["wheel" "networkmanager" "gpio" "i2c" "spi"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # Zsh configuration
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    autosuggestions.enable = true;
  };

  # Common packages (lighter set for Pi)
  environment.systemPackages = with pkgs; [
    curl
    fd
    file
    git
    htop
    jq
    ripgrep
    tmux
    tree
    vim
    wget
  ];

  # Enable nix flakes
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.settings.trusted-users = ["root" "amadeus"];

  system.stateVersion = "25.05";
}
