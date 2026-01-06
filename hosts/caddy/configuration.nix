{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
  ];

  networking.hostName = "caddy";

  # Caddy reverse proxy configuration
  services.caddy = {
    enable = true;
    globalConfig = ''
      auto_https off
    '';

    # Example virtual hosts - customize as needed
    virtualHosts = {
      "http://localhost" = {
        extraConfig = ''
          respond "Caddy is running!" 200
        '';
      };

      # Example reverse proxy configuration
      # "app.local.lan" = {
      #   extraConfig = ''
      #     reverse_proxy http://10.0.0.10:8080
      #   '';
      # };
    };
  };

  # Firewall configuration for web server
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22 # SSH
      80 # HTTP
      443 # HTTPS
    ];
  };

  # Additional packages for web server management
  environment.systemPackages = with pkgs; [
    curl
    openssl
    certbot
  ];

  # Enable automatic certificate renewal if using Let's Encrypt
  # security.acme = {
  #   acceptTerms = true;
  #   defaults.email = "admin@example.com";
  # };
}
