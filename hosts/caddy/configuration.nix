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

  environment.etc."caddy-index" = {
    target = "/var/www/index.html";
    user = "caddy";
    group = "caddy";
    mode = "0644";
    text = ''
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
  };

  systemd.tmpfiles.rules = [
    "d /var/www 0755 caddy caddy -"
  ];

  # Caddy reverse proxy configuration
  services.caddy = {
    enable = true;
    globalConfig = ''
      auto_https off
    '';

    # Serve the demo page on both localhost and the LAN IP
    virtualHosts = let
      staticSite = ''
        root * /var/www
        file_server
      '';
    in {
      "http://localhost" = {
        extraConfig = staticSite;
      };
      "http://192.168.2.131" = {
        extraConfig = staticSite;
      };
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
