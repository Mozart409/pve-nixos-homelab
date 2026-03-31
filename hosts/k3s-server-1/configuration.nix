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

  networking.hostName = "k3s-server-1";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.157";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.145" "1.1.1.1"];

  # K3s Server (Control Plane)
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--node-name=k3s-server-1"
      "--disable=traefik" # We'll use our own ingress
      "--disable=servicelb" # Disable built-in load balancer
      "--tls-san=192.168.2.157"
      "--tls-san=k3s-server-1"
      "--tls-san=k3s-server-1.dropbear-butterfly.ts.net"
    ];
  };

  # Install kubectl and helm
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
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
      6443  # Kubernetes API
      2379  # etcd client
      2380  # etcd peer
      10250 # Kubelet
      10251 # kube-scheduler
      10252 # kube-controller-manager
      9100  # Node exporter
    ];
    allowedUDPPorts = [
      8472  # Flannel VXLAN
    ];
  };
}
