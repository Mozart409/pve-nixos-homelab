{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ./uptime-forge
  ];

  networking.hostName = "homelab-containers";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.149";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  # Prometheus exporters
  services.prometheus = {
    exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
    };
    exporters.postgres = {
      enable = true;
      environmentFile = "/run/uptime-forge/postgres-exporter.env";
    };
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP
      443 # HTTPS
      3000 # Uptime Forge
      5444 # TimescaleDB (external access)
      9100 # Node exporter
      9187 # Postgres exporter
    ];
  };
}
