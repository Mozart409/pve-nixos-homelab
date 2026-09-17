{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/albyhub";
in {
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    albyhub = {
      image = "ghcr.io/getalby/hub:v1.22.2";
      autoStart = true;
      # Loopback only: Caddy (hosts/containers/configuration.nix) terminates
      # TLS and is the only client. Published on 0.0.0.0 this was the wallet
      # UI + API over plain HTTP to the whole LAN.
      ports = ["127.0.0.1:8080:8080"];
      volumes = [
        "${dataDir}:/data"
      ];
      environment = {
        WORK_DIR = "/data/albyhub";
      };
      extraOptions = [
        "--stop-timeout=300"
      ];
    };
  };
}
