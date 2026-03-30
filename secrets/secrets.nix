let
  amadeus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan";
  hostDatabase = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOzKKGEVZy4w556Y3n1KQQrWVJUxU7XfHULii9W1qTr amadeus@homelab-database";
  hostOtel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGz4mCD5XyFkwVaSzzWHhral8WqMGo01nKZM3gAX2vzP amadeus@homelab-otel";
  hostDns = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILXKgvCX3XImCFgba09r+oEezHtDjG5zTPszYqOalfc3 root@homelab-dns";
  hostUnifi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1dva0wW3yY7pu0bT2HafVcn08BZMjzTwEh3CGcdfb8 root@homelab-unifi";
  hostContainers = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKHmDtkEG9WNd6bvbEM3+HhdfnSu29o5bYskujiM6VdF root@homelab-containers";
  hostMcp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGkfmvav5dWx4dAbDHcJSuKG32GSmdVdOK+uQ1xjCtse root@homelab-mcp";
  hostHermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBloNkev1cC0W2YBDi0Qk0adUqVwWve1oXK4X5PYnds root@homelab-hermes";
  users = [amadeus hostDatabase hostOtel hostDns hostUnifi hostContainers hostMcp hostHermes];
in {
  "tailscale-auth-key.age".publicKeys = users;
  "uptime-forge-db-password.age".publicKeys = [amadeus hostContainers];
  "harbor-db-password.age".publicKeys = [amadeus hostContainers];
  "harbor-admin-password.age".publicKeys = [amadeus hostContainers];
  "harbor-core-secret.age".publicKeys = [amadeus hostContainers];
  "homeassistant-token.age".publicKeys = [amadeus hostMcp];
  "grafana-secret-key.age".publicKeys = [amadeus hostOtel];
  "pgadmin-pwd.age".publicKeys = [amadeus hostDatabase];
  "hermes-opencode-zen-key.age".publicKeys = [amadeus hostHermes];
}
