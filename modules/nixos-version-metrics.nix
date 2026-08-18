{
  config,
  lib,
  pkgs,
  ...
}: let
  textfileDir = "/var/lib/node_exporter/textfile";

  generationScript = ''
    gen=0
    system_link=$(readlink -f /run/current-system 2>/dev/null || echo "")
    if [ -n "$system_link" ]; then
      gen=$(echo "$system_link" | sed 's/.*-system-//')
    fi
    echo "$gen"
  '';
in {
  # Enable the node_exporter textfile collector
  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=${textfileDir}"
  ];

  # Ensure the textfile directory exists
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
  ];

  # Write NixOS version metrics on every activation so node_exporter exposes
  # them at the /metrics endpoint. Uses atomic write (temp file + mv) so
  # node_exporter never reads a partially-written file.
  system.activationScripts.nixosVersionMetrics = {
    text = ''
      mkdir -p ${textfileDir}
      tmp=${textfileDir}/nixos.prom.$$
      cat > "$tmp" <<PROM
      # HELP nixos_info NixOS release and kernel version
      # TYPE nixos_info gauge
      nixos_info{version="${config.system.nixos.release}",kernel_version="${config.boot.kernelPackages.kernel.version}"} 1
      # HELP nixos_system_build_timestamp_seconds Unix timestamp of the current NixOS system generation
      # TYPE nixos_system_build_timestamp_seconds gauge
      nixos_system_build_timestamp_seconds $(stat -c %Y /run/current-system 2>/dev/null || echo 0)
      # HELP nixos_system_generation Current NixOS generation number
      # TYPE nixos_system_generation gauge
      nixos_system_generation $(${generationScript})
      PROM
      mv "$tmp" ${textfileDir}/nixos.prom
    '';
    deps = [];
  };
}
