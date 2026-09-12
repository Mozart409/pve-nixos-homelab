{
  config,
  lib,
  pkgs,
  ...
}: let
  # The host zone (modules/common.nix). Captured here because inside the
  # submodule below `config` would otherwise be shadowed by the container's own.
  hostTimeZone = config.time.timeZone;
in {
  # Every container runs in the host's timezone. Podman does not propagate the
  # host zone: without this each image fell back to UTC (axon-gateway logged
  # `…T08:08:05Z` while the host was Europe/Berlin; the TimescaleDB container's
  # Postgres ran on UTC too -- audited 2026-09-12). Two mechanisms because
  # images differ: `TZ` is honoured by anything that ships tzdata (glibc, Go,
  # Rust), while a bind-mounted `/etc/localtime` covers alpine / photon /
  # distroless images that carry no zoneinfo at all. The mount is the real file
  # from pkgs.tzdata, not the host's /etc/localtime -- that is a symlink into
  # /nix/store which would dangle inside the container.
  #
  # Declared as a submodule extension of the upstream option so it applies to
  # every container on the host by construction; a container that needs a
  # different zone overrides `environment.TZ` with mkForce.
  options.virtualisation.oci-containers.containers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      config = {
        environment.TZ = lib.mkDefault hostTimeZone;
        volumes = [
          "${pkgs.tzdata}/share/zoneinfo/${hostTimeZone}:/etc/localtime:ro"
        ];
      };
    });
  };

  config = {
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
  };
}
