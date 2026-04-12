let
  amadeus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan";
  hostDatabase = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOzKKGEVZy4w556Y3n1KQQrWVJUxU7XfHULii9W1qTr amadeus@homelab-database";
  hostOtel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGz4mCD5XyFkwVaSzzWHhral8WqMGo01nKZM3gAX2vzP amadeus@homelab-otel";
  hostDns = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILXKgvCX3XImCFgba09r+oEezHtDjG5zTPszYqOalfc3 root@homelab-dns";
  hostUnifi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1dva0wW3yY7pu0bT2HafVcn08BZMjzTwEh3CGcdfb8 root@homelab-unifi";
  hostContainers = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKHmDtkEG9WNd6bvbEM3+HhdfnSu29o5bYskujiM6VdF root@homelab-containers";
  hostMcp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGkfmvav5dWx4dAbDHcJSuKG32GSmdVdOK+uQ1xjCtse root@homelab-mcp";
  hostHermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBloNkev1cC0W2YBDi0Qk0adUqVwWve1oXK4X5PYnds root@homelab-hermes";
  hostK3sServer1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILK0KcBwr2zXxl97/JjpFRBD38XpG0wEWZjkIQgarRcJ root@k3s-server-1";
  hostK3sWorker1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMtwgQdHZdj7KSSmzc5nI02kzRIUqV26A2B4D/dbEpj7 root@homelab-minimal root@k3s-worker-1";
  users = [amadeus hostDatabase hostOtel hostDns hostUnifi hostContainers hostMcp hostHermes hostK3sServer1 hostK3sWorker1];
in {
  "tailscale-auth-key.age".publicKeys = users;
  "uptime-forge-db-password.age".publicKeys = [amadeus hostContainers];
  "harbor-db-password.age".publicKeys = [amadeus hostContainers];
  "harbor-admin-password.age".publicKeys = [amadeus hostContainers];
  "harbor-core-secret.age".publicKeys = [amadeus hostContainers];
  "homeassistant-token.age".publicKeys = [amadeus hostMcp];
  "grafana-secret-key.age".publicKeys = [amadeus hostOtel];
  "grafana-oidc-secret.age".publicKeys = [amadeus hostOtel];
  "pgadmin-pwd.age".publicKeys = [amadeus hostDatabase];
  "terraform-state-db-password.age".publicKeys = [amadeus hostDatabase];
  "hermes-opencode-zen-key.age".publicKeys = [amadeus hostHermes];
  "hermes-api-server-key.age".publicKeys = [amadeus hostHermes];
  "k3s-server-token.age".publicKeys = [amadeus hostK3sServer1 hostK3sWorker1];
}
