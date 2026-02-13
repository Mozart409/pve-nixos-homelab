let
  amadeus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan";
  hostDatabase = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOzKKGEVZy4w556Y3n1KQQrWVJUxU7XfHULii9W1qTr amadeus@homelab-database";
  hostOtel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGz4mCD5XyFkwVaSzzWHhral8WqMGo01nKZM3gAX2vzP amadeus@homelab-otel";
  hostDns = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILXKgvCX3XImCFgba09r+oEezHtDjG5zTPszYqOalfc3 root@homelab-dns";
  hostUnifi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1dva0wW3yY7pu0bT2HafVcn08BZMjzTwEh3CGcdfb8 root@homelab-unifi";
  # TODO: Add containers host key after deployment
  # hostContainers = "ssh-ed25519 AAAA... root@homelab-containers";
  users = [amadeus hostDatabase hostOtel hostDns hostUnifi];
  # Hosts that need uptime-forge secrets
  uptimeForgeHosts = [amadeus]; # Add hostContainers here after deployment
in {
  "tailscale-auth-key.age".publicKeys = users;
  "uptime-forge-db-password.age".publicKeys = uptimeForgeHosts;
}
