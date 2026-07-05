{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/romm";

  # RomM connects to the central PostgreSQL host (hosts/database, 192.168.2.134)
  # instead of the bundled MariaDB from the upstream compose. The DB password
  # lives in romm-db-password.age (shared with the database host, which sets the
  # matching role password) and is injected at runtime as DB_PASSWD.
  generateDbEnv = pkgs.writeShellScript "generate-romm-db-env" ''
    mkdir -p /run/romm
    DB_PASSWORD=$(cat ${config.age.secrets.romm-db-password.path})
    printf 'DB_PASSWD=%s\n' "$DB_PASSWORD" > /run/romm/db.env
    chmod 600 /run/romm/db.env
  '';
in {
  # Persistent host paths for the game library, uploaded saves/states and config.
  # resources (IGDB covers/screenshots) and the internal redis cache use named
  # podman volumes, mirroring the upstream compose.
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/library 0755 root root -"
    "d ${dataDir}/assets 0755 root root -"
    "d ${dataDir}/config 0755 root root -"
  ];

  # App secrets: ROMM_AUTH_SECRET_KEY, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET and the
  # metadata-provider keys (SCREENSCRAPER_*, RETROACHIEVEMENTS_API_KEY).
  # Read by systemd as root before the container starts.
  age.secrets.romm-env = {
    file = ../../../secrets/romm-env.age;
    mode = "0400";
  };

  # DB password (shared with the database host). Root reads it in ExecStartPre to
  # generate /run/romm/db.env.
  age.secrets.romm-db-password = {
    file = ../../../secrets/romm-db-password.age;
    mode = "0400";
  };

  # RomM - self-hosted ROM manager. Single container: the image bundles its own
  # redis (persisted to /redis-data), so no separate redis container is needed.
  # Binds 127.0.0.1:8095 -> 8080; Caddy (see ../configuration.nix) is the only
  # thing that proxies to it, terminating step-ca TLS at romm.homelab.local.
  virtualisation.oci-containers.containers.romm = {
    image = "rommapp/romm:latest";
    autoStart = true;
    ports = ["127.0.0.1:8095:8080"];
    volumes = [
      "romm_resources:/romm/resources"
      "romm_redis_data:/redis-data"
      "${dataDir}/library:/romm/library"
      "${dataDir}/assets:/romm/assets"
      "${dataDir}/config:/romm/config"
    ];
    environment = {
      # Database - central PostgreSQL host (hosts/database).
      ROMM_DB_DRIVER = "postgresql";
      DB_HOST = "192.168.2.134";
      DB_PORT = "5432";
      DB_NAME = "romm";
      DB_USER = "romm";

      # Metadata providers.
      HASHEOUS_API_ENABLED = "true";

      # OIDC via Pocket ID (same provider as open-webui / harbor). The redirect
      # URI and base URL must exactly match the callback registered in Pocket ID.
      OIDC_ENABLED = "true";
      OIDC_PROVIDER = "pocket-id";
      OIDC_REDIRECT_URI = "https://romm.homelab.local/api/oauth/openid";
      OIDC_SERVER_APPLICATION_URL = "https://pocketid.dropbear-butterfly.ts.net";
      ROMM_BASE_URL = "https://romm.homelab.local";
    };
    # db.env (DB_PASSWD, generated at runtime) + romm-env.age (app/OIDC secrets).
    environmentFiles = [
      "/run/romm/db.env"
      config.age.secrets.romm-env.path
    ];
  };

  # Generate /run/romm/db.env from the agenix secret before the container starts.
  systemd.services.podman-romm.serviceConfig.ExecStartPre = ["${generateDbEnv}"];
}
