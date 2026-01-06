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

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.131";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = ["192.168.2.1" "1.1.1.1"];

  environment.etc."/var/lib/caddy/index.html".text = ''
    <html>
      <head>
        <title>Demo</title>
        <link rel="stylesheet" href="https://cdn.simplecss.org/simple.css" />
      </head>
      <body>
        <main>
          <h1>Hello World</h1>
        </main>
      </body>
    </html>
  '';

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
          root * /var/lib/caddy
          file_server
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
