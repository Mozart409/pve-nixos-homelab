{pkgs, ...}: {
  # Client tooling for talking to the single-node k3s cluster
  # (hosts/k3s-server-1). No kubeconfig wiring here -- each consumer sets up
  # its own access (e.g. copying /etc/rancher/k3s/k3s.yaml from the server).
  environment.systemPackages = with pkgs; [
    k9s
    kubectl
    kubernetes-helm
    kubie
  ];
}
