let
  # keep-sorted start
  amadeus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan";
  amadeusAge = "age1uslcewyhmagupmfg4nf9tc6alj8edapzexnjvuhrkkmwd3wmy4nqpmel7t";
  amadeusMacbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH/HCRJuzlIbgcWk68ehApZl6kN+7PnKIgYSLRZ5IjzQ amadeus@Amadeuss-MacBook-Pro.local";
  hostBuildBotMaster = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwy8ohPS5E6ElmFvYoNYNBfbiYjAfFQBVtBA5hePSiN root@homelab-buildbot-master";
  hostBuildBotWorker1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIIZK5rnXUBhINU4lzEWkhxhdRWsLR7IxLeQID8HqLKF root@homelab-buildbot-worker-1";
  hostCa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP8qC6ErJ2PUjNlIwchBMyAWeRDVB6to2cNSnnDqmD+x root@homelab-ca";
  hostCache = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3zPdNuF7/Xwxxhs6isTeG1K3fodO+lbQdWcfZUid4k root@homelab-cache";
  hostContainers = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKHmDtkEG9WNd6bvbEM3+HhdfnSu29o5bYskujiM6VdF root@homelab-containers";
  hostDatabase = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOzKKGEVZy4w556Y3n1KQQrWVJUxU7XfHULii9W1qTr amadeus@homelab-database";
  hostDevelopment = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINpHEt4OMS5HwaSunrmU68JzkM2gu1MVcXqKZSQAhMe8 root@homelab-development";
  hostDns = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILXKgvCX3XImCFgba09r+oEezHtDjG5zTPszYqOalfc3 root@homelab-dns";
  hostFleet = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLI6UX6dd+pyXOd8TIQ3NY3Ryff2gCH4oTd1YWjvzm8 root@homelab-fleet";
  hostForgejo = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIByBR3nP+bKlGcC6p62Pg5w1cPZsdh1FHBE6RUfbchDo root@homelab-forgejo";
  hostHarbor = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJmT6FxRSlang9smAuBoq1QhYGtQ4adP4kK1lkLn8Ip root@homelab-harbor";
  hostHermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBloNkev1cC0W2YBDi0Qk0adUqVwWve1oXK4X5PYnds root@homelab-hermes";
  hostJellyfin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDjBjNv4pvr08UdR2QL72Re3B22cUV+3DQvR2oG3/nsA root@homelab-jellyfin";
  hostK3sServer1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILK0KcBwr2zXxl97/JjpFRBD38XpG0wEWZjkIQgarRcJ root@k3s-server-1";
  hostK3sWorker1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMtwgQdHZdj7KSSmzc5nI02kzRIUqV26A2B4D/dbEpj7 root@homelab-minimal root@k3s-worker-1";
  hostMcp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGkfmvav5dWx4dAbDHcJSuKG32GSmdVdOK+uQ1xjCtse root@homelab-mcp";
  hostOtel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGz4mCD5XyFkwVaSzzWHhral8WqMGo01nKZM3gAX2vzP amadeus@homelab-otel";
  hostUnifi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1dva0wW3yY7pu0bT2HafVcn08BZMjzTwEh3CGcdfb8 root@homelab-unifi";
  hostWoodpecker = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIACJjy5GtvoeSP5muZFLj3/rMvIAlm7gfXZ80micVVgm root@homelab-woodpecker";
  hostZeroclaw = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF8hvOMPXx4HOK9/yxL/r8oj1itQIFQDpnk362IwrIfy root@homelab-minimal";
  users = [amadeus amadeusAge amadeusMacbook hostDatabase hostOtel hostDns hostUnifi hostContainers hostMcp hostHermes hostK3sServer1 hostK3sWorker1 hostCa hostFleet hostHarbor hostCache hostForgejo hostBuildBotMaster hostBuildBotWorker1 hostJellyfin hostZeroclaw hostDevelopment hostWoodpecker];
  # keep-sorted end
in {
  # keep-sorted start

  "attic-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase]; # raw password; same value inside attic-db-url.age
  "attic-db-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostCache]; # env-file: ATTIC_SERVER_DATABASE_URL=postgresql://...
  "attic-push-token.age".publicKeys = [amadeusAge hostCa hostCache hostContainers hostDatabase hostDevelopment hostDns hostFleet hostForgejo hostHarbor hostHermes hostJellyfin hostMcp hostOtel hostUnifi hostWoodpecker]; # plain JWT, not KEY=value
  "attic-server-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostCache];
  "axon-gateway-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers hostHermes hostDevelopment hostOtel hostZeroclaw];
  "buildbot-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostBuildBotMaster];
  "buildbot-webhook-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostBuildBotMaster];
  "buildbot-worker-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostBuildBotMaster hostBuildBotWorker1];
  "dashboard-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers];
  "development-forgejo-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDevelopment];
  "development-opencode-zen-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDevelopment];
  "fleet-enroll-secret.age".publicKeys = users;
  "fleet-mysql-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostFleet];
  "forgejo-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostForgejo hostDatabase];
  "futo-notes-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers hostDatabase];
  "futo-notes-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers];
  "garage-rpc-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostCache];
  "grafana-oidc-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostOtel];
  "grafana-secret-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostOtel];
  "harbor-admin-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHarbor];
  "harbor-core-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHarbor];
  "harbor-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHarbor];
  "harbor-oidc-client-id.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHarbor];
  "harbor-oidc-client-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHarbor];
  "hermes-agentmail-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes];
  "hermes-api-server-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes];
  "hermes-deepseek-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes];
  "hermes-forgejo-ssh.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes];
  "hermes-opencode-zen-key.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes];
  "hofvarpnir-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase hostJellyfin];
  "hofvarpnir-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostJellyfin];
  "homeassistant-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "k3s-server-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostK3sServer1 hostK3sWorker1];
  "moshi-device-id.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostHermes hostDevelopment hostZeroclaw]; # plain auth token
  "open-webui-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers];
  "pbs-mcp-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-appdb-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-appuser-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-forgejo-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-hofvarpnir-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-romm-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-terraform-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pg-mcp-uptime-url.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp];
  "pgadmin-oauth2-secret.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase];
  "pgadmin-pwd.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase];
  "pgmcp-role-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase];
  "postgres-superuser-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase];
  "romm-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers hostDatabase];
  "romm-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers];
  "step-ca-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostCa];
  "tailscale-auth-key.age".publicKeys = users;
  "terraform-state-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDatabase];
  "uptime-forge-db-password.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostContainers];
  "ventara-gateway-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostDevelopment];
  "woodpecker-agent-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostWoodpecker]; # WOODPECKER_AGENT_SECRET only; must match the server's byte-for-byte
  "woodpecker-mcp-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostMcp]; # WP_TOKEN for wpmcp-server; a Woodpecker personal access token
  "woodpecker-metrics-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostOtel]; # bare bearer token for prometheus; same value as WOODPECKER_PROMETHEUS_AUTH_TOKEN in woodpecker-server-env.age
  "woodpecker-server-env.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostWoodpecker]; # WOODPECKER_AGENT_SECRET, WOODPECKER_GRPC_SECRET, WOODPECKER_FORGEJO_CLIENT, WOODPECKER_FORGEJO_SECRET
  # keep-sorted end
}
