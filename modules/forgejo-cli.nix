{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.forgejo-cli
  ];
}
