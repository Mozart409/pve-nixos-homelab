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
    ../../modules/step-ca-trust.nix
    ../../modules/osquery.nix
  ];

  networking.hostName = "k3s-agent-1";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.156";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # K3s token secret
  age.secrets.k3s-server-token = {
    file = ../../secrets/k3s-server-token.age;
  };

  # K3s Agent (Worker Node)
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.2.157:6443";
    tokenFile = config.age.secrets.k3s-server-token.path;
    extraFlags = toString [
      "--node-name=k3s-agent-1"
    ];
  };

  # Install kubectl for debugging
  environment.systemPackages = with pkgs; [
    kubectl
    k9s
  ];

  # Prometheus node exporter
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0" "cni0" "flannel.1"];
    allowedTCPPorts = [
      22 # SSH
      10250 # Kubelet
      9100 # Node exporter
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
    ];
  };
}
