{
  config,
  pkgs,
  ...
}: {
  services.tailscale.enable = true;

  # Tailscale requires loose reverse path filtering
  networking.firewall.checkReversePath = "loose";

  # Define the secret
  age.secrets.tailscale-auth-key.file = ../secrets/tailscale-auth-key.age;

  # Use the secret for authentication
  services.tailscale.authKeyFile = config.age.secrets.tailscale-auth-key.path;

  # Ensure the auth key is available before autoconnect runs
  systemd.services.tailscaled-autoconnect = {
    after = ["agenix.service"];
    requires = ["agenix.service"];
  };
}
