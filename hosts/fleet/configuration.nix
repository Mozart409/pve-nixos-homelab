{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../modules/common.nix
    ../../modules/disko-config.nix
    ../../modules/tailscale.nix
    ../../modules/step-ca-trust.nix
  ];

  networking.hostName = "homelab-fleet";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.164";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # MySQL database for Fleet
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    settings = {
      mysqld = {
        bind-address = "127.0.0.1";
        port = 3306;
      };
    };
    ensureDatabases = ["fleet"];
    ensureUsers = [
      {
        name = "fleet";
        ensurePermissions = {
          "fleet.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };

  # Redis for Fleet
  services.redis.servers.fleet = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
  };

  # Fleet server user
  users.users.fleet = {
    isSystemUser = true;
    group = "fleet";
    description = "Fleet server user";
  };
  users.groups.fleet = {};

  # Fleet server binaries
  environment.systemPackages = [
    pkgs.fleet
    pkgs.fleetctl
  ];

  # Fleet configuration directory
  environment.etc."fleet/fleet.yml" = {
    user = "fleet";
    group = "fleet";
    mode = "0640";
    text = ''
      mysql:
        address: 127.0.0.1:3306
        database: fleet
        username: fleet
        password: ""
        max_open_conns: 50
        max_idle_conns: 25
        conn_max_lifetime: 3600

      redis:
        address: 127.0.0.1:6379
        database: "0"

      server:
        address: 0.0.0.0:8080
        cert: /var/lib/fleet/certs/server.crt
        key: /var/lib/fleet/certs/server.key

      logging:
        json: true
        debug: false

      osquery:
        enroll_cooldown: 5m
    '';
  };

  # Fleet systemd service
  systemd.services.fleet = {
    description = "Fleet osquery management server";
    after = ["network.target" "mysql.service" "redis-fleet.service"];
    requires = ["mysql.service" "redis-fleet.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = "${pkgs.fleet}/bin/fleet serve --config /etc/fleet/fleet.yml";
      User = "fleet";
      Group = "fleet";
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "fleet";
      StateDirectoryMode = "0750";
    };
  };

  # Prometheus node exporter
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # Caddy reverse proxy with Tailscale TLS
  services.caddy = {
    enable = true;

    virtualHosts."homelab-fleet.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        reverse_proxy localhost:8080
      '';
    };

    virtualHosts."fleet.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        reverse_proxy localhost:8080
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy.serviceConfig.BindPaths = "/var/run/tailscale/tailscaled.sock";

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS (Caddy)
      8080 # Fleet server
      9100 # Node exporter
    ];
  };
}
