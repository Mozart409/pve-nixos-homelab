{
  config,
  pkgs,
  ...
}: {
  # Shared token every server/agent node in the cluster authenticates with.
  # `just get-host-key <ip>` + add to secrets/secrets.nix + `just reencrypt`
  # once a node is actually installed and its real SSH host key is known --
  # see the "Reprovisioned Host" pitfall in AGENTS.md.
  age.secrets.k3s-server-token = {
    file = ../secrets/k3s-server-token.age;
    owner = "root";
    mode = "0400";
  };

  services.k3s = {
    enable = true;
    role = "server";
    # First server in the cluster bootstraps its own embedded etcd datastore;
    # additional k3s-cntrl-N servers join it later via --server=https://... to
    # form an HA control plane instead of k3s' default single-node SQLite.
    clusterInit = true;
    tokenFile = config.age.secrets.k3s-server-token.path;
  };

  environment.systemPackages = [pkgs.kubectl];

  networking.firewall = {
    allowedTCPPorts = [
      6443 # k3s / Kubernetes API server
      2379 # etcd client
      2380 # etcd peer
      10250 # kubelet
      80 # Traefik ingress (bundled k3s addon)
      443 # Traefik ingress (bundled k3s addon)
    ];
    allowedUDPPorts = [
      8472 # flannel VXLAN (default CNI backend)
    ];
  };
}
