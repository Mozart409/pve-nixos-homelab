{
  config,
  lib,
  pkgs,
  ...
}: {
  # Podman only — no Docker compatibility shim. dockerCompat installs a `docker`
  # binary aliasing podman (and a /run/docker.sock symlink); nothing in this repo
  # calls either, so it only invited people to reach for docker muscle memory.
  # Use `podman` / `podman-compose` directly.
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Set backend for OCI containers
  virtualisation.oci-containers.backend = "podman";
}
