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
      ports = ["8080:8080"];
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
