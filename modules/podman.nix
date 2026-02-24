{
  config,
  lib,
  pkgs,
  ...
}: {
  # Enable Podman with Docker compatibility
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Set backend for OCI containers
  virtualisation.oci-containers.backend = "podman";
}
