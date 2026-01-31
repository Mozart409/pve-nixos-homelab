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
  ];

  networking.hostName = "homelab-otel";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.135";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  # OpenTelemetry Collector (contrib build)
  users.users.otelcol = {
    isSystemUser = true;
    group = "otelcol";
    description = "OpenTelemetry Collector user";
  };
  users.groups.otelcol = {};

  environment.etc."otelcol/config.yaml" = {
    user = "otelcol";
    group = "otelcol";
    mode = "0644";
    text = ''
      receivers:
        otlp:
          protocols:
            grpc:
            http:

      processors:
        batch: {}

      exporters:
        debug:
          verbosity: basic

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
    '';
  };

  systemd.services.otel-collector = {
    description = "OpenTelemetry Collector";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = ''${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config /etc/otelcol/config.yaml'';
      User = "otelcol";
      Group = "otelcol";
      Restart = "on-failure";
      RestartSec = 5;
      CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
      AmbientCapabilities = "CAP_NET_BIND_SERVICE";
    };
  };

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      4317 # OTLP gRPC
      4318 # OTLP HTTP
      8888 # Collector metrics
    ];
  };

  environment.systemPackages = with pkgs; [
    opentelemetry-collector-contrib
  ];
}
