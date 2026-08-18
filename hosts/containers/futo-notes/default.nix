{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/futo-notes";

  # FUTO Notes connects to the central PostgreSQL host (hosts/database).
  # The DB password lives in futo-notes-db-password.age (shared with the
  # database host, which sets the matching role password) and is injected
  # at runtime as part of the DATABASE_URL.
  generateDbEnv = pkgs.writeShellScript "generate-futo-notes-db-env" ''
    mkdir -p /run/futo-notes
    DB_PASSWORD=$(cat ${config.age.secrets.futo-notes-db-password.path})
    printf 'DATABASE_URL=postgres://futo_notes:%s@192.168.2.134:5432/futo_notes\n' "$DB_PASSWORD" > /run/futo-notes/db.env
    chmod 600 /run/futo-notes/db.env
  '';
in {
  # Persistent host directory for encrypted note blobs.
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/blobs 0755 root root -"
  ];

  # DB password (shared with the database host). Root reads it in
  # ExecStartPre to generate /run/futo-notes/db.env.
  age.secrets.futo-notes-db-password = {
    file = ../../../secrets/futo-notes-db-password.age;
    mode = "0400";
  };

  # Auth password for FUTO Notes login. Plain KEY=value env file.
  age.secrets.futo-notes-env = {
    file = ../../../secrets/futo-notes-env.age;
    mode = "0400";
  };

  # FUTO Notes Server — E2E-encrypted sync server for the FUTO Notes app.
  # The server stores opaque encrypted blobs and never sees plaintext.
  # Binds 127.0.0.1:3006 -> 3000; Caddy proxies with step-ca TLS at
  # notes.homelab.local. Uses central PostgreSQL (hosts/database).
  virtualisation.oci-containers.containers.futo-notes = {
    image = "gitlab.futo.org:5050/futo-notes/futo-notes-server/server:stable";
    autoStart = true;
    ports = ["127.0.0.1:3006:3000"];
    volumes = [
      "${dataDir}/blobs:/data/blobs"
    ];
    environment = {
      PORT = "3000";
      BLOB_DIR = "/data/blobs";
      LOG_LEVEL = "info";
      AUTH_MODE = "password";
    };
    # db.env (DATABASE_URL, generated at runtime) + futo-notes-env.age (FUTO_NOTES_PASSWORD).
    environmentFiles = [
      "/run/futo-notes/db.env"
      config.age.secrets.futo-notes-env.path
    ];
  };

  # Generate /run/futo-notes/db.env from the agenix secret before the
  # container starts.
  systemd.services.podman-futo-notes.serviceConfig.ExecStartPre = ["${generateDbEnv}"];
}
