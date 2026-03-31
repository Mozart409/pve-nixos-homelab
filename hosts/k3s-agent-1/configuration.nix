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

  networking.hostName = "k3s-agent-1";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.161";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.145" "1.1.1.1"];

  # K3s Agent (Worker Node)
  # Note: After deploying k3s-server, get the token from:
  # /var/lib/rancher/k3s/server/node-token
  # Then set it via agenix secret or environment variable
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.2.160:6443";
    # tokenFile = config.age.secrets.k3s-token.path;
    # Uncomment above and add secret after k3s-server is deployed
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
      22    # SSH
      10250 # Kubelet
      9100  # Node exporter
    ];
    allowedUDPPorts = [
      8472  # Flannel VXLAN
    ];
  };
}
