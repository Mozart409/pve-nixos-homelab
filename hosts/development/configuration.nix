{pkgs, ...}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
    ../../modules/podman.nix
    ../../modules/moshi-hook-user.nix
    ../../modules/coding-harness.nix
    ../../modules/herdr.nix
  ];

  networking.hostName = "homelab-development";

  # This VM has TWO disks — the 256 GB OS disk (scsi0) and a 4 MB cloud-init
  # drive on the ATA bus — so /dev/sdX enumeration is not stable and disko could
  # target the cloud-init disk inside the nixos-anywhere installer. Override
  # modules/disko-config.nix's lib.mkDefault "/dev/sda" with the stable by-id
  # path. See AGENTS.md §6 "Multi-Disk VMs: Pin Disko Devices by /dev/disk/by-id".
  disko.devices.disk.main.device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.184";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Podman (+ Docker compat, container DNS) comes from ../../modules/podman.nix

  networking.firewall = {
    enable = true;
    # podman+ = every podman bridge (podman0 plus any per-experiment network).
    # Without trusting them the host firewall drops container -> aardvark-dns
    # traffic, so containers can't resolve each other. See harbor's podman1 note.
    trustedInterfaces = ["tailscale0" "podman+"];
    allowedTCPPorts = [
      22 # SSH
      9100 # Node exporter
    ];
  };

  # Moshi pairing token (plain raw text, NOT KEY=value — read directly by
  # modules/moshi-hook-user.nix's pair script). Owned by amadeus so
  # moshi-hook-setup (User=amadeus) can read it.
  age.secrets.moshi-device-id = {
    file = ../../secrets/moshi-device-id.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Axon MCP gateway bearer token (file contains AXON_GATEWAY_TOKEN=...).
  # Owned by amadeus: modules/coding-harness.nix sources it directly into
  # every interactive login shell (environment.interactiveShellInit) so
  # Claude Code / opencode can expand it from their MCP config at runtime.
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    owner = "amadeus";
    mode = "0400";
  };

  # opencode-zen provider key (env-file: OPENCODE_ZEN_API_KEY=...). Declared
  # under the generic `opencode-zen-key` attribute that modules/coding-harness.nix
  # looks for, while the file itself is per-host — every consumer gets its own
  # key so a leak is contained and revocation is per-host. hermes keeps its own
  # separate hermes-opencode-zen-key.age.
  age.secrets.opencode-zen-key = {
    file = ../../secrets/development-opencode-zen-key.age;
    owner = "amadeus";
    mode = "0400";
  };

  # Development tools for experiments
  environment.systemPackages = with pkgs; [
    # keep-sorted start
    bat
    # bun + nodejs: opencode's global plugins (~/.config/opencode/plugins/
    # moshi-hooks.ts, herdr-agent-state.js) import @opencode-ai/plugin and
    # bun:sqlite, and opencode bootstraps their node_modules on first run.
    bun
    claude-code
    curl
    delta
    eza
    fd
    fzf
    git
    htop
    httpie
    jq
    lazygit
    neovim
    nodejs
    opencode
    podman-compose
    ripgrep
    tmux
    wget
    yq
    # keep-sorted end
  ];
}
