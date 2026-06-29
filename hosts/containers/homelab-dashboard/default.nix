{
  config,
  homelab-dashboard,
  ...
}: {
  imports = [homelab-dashboard.nixosModules.default];

  # The systemd service runs the `homelab-dashboard` package from the flake's
  # overlay, so the overlay must be active on this host's pkgs.
  nixpkgs.overlays = [homelab-dashboard.overlays.default];

  services.homelab-dashboard = {
    enable = true;
    # Fronted by Caddy (dashboard.homelab.local), like searxng/axon/pbs-mcp.
    # Bind to localhost only; do not open it directly to the LAN.
    openFirewall = false;
    settings = {
      listen_address = "127.0.0.1";
      port = 8084; # 8080 is taken by AlbyHub on this host
      search = {
        tyoe = "searxng";
        url = "https://searxng.dropbear-butterfly.ts.net";
      };
      weather = {
        latitude = 48.1374;
        longitude = 11.5755;
        location = "Munich";
      };
      hofvarpnir.url = "https://hofvarpnir.dropbear-butterfly.ts.net";
      health_checks = [
        {
          name = "Router";
          url = "http://192.168.2.1";
        }
        {
          name = "step-ca";
          url = "https://ca.homelab.local:8443";
        }
        {
          name = "DNS";
          url = "http://192.168.2.145";
        }
        {
          name = "Forgejo";
          url = "https://forgejo.homelab.local";
        }
        {
          name = "Harbor";
          url = "https://harbor.homelab.local";
        }
        {
          name = "SearXNG";
          url = "https://searxng.homelab.local";
        }
        {
          name = "Open WebUI";
          url = "https://containers.homelab.local";
        }
        {
          name = "Uptime Forge";
          url = "http://192.168.2.149:3000";
        }
        {
          name = "Grafana";
          url = "http://192.168.2.135:3000";
        }
        {
          name = "Nix Cache";
          url = "https://cache.homelab.local";
        }
        {
          name = "UniFi";
          url = "https://192.168.2.142:8443";
          timeout_ms = 5000;
        }
        {
          name = "Hermes";
          url = "https://hermes.homelab.local";
        }
      ];
    };

    # Env file holding dashboard secrets (HOFVARPNIR_API_KEY, and any added
    # later). Loaded as the service's systemd EnvironmentFile. To add more
    # secrets in the future just append KEY=value lines — no Nix changes needed:
    #   agenix -e secrets/dashboard-env.age   (run from the repo, in the dev shell)
    secretsFile = config.age.secrets.dashboard-env.path;
  };

  # The homelab-dashboard service runs as a systemd DynamicUser, so there is no
  # static user/group to chown to. systemd reads EnvironmentFile as root before
  # dropping privileges, so root-only (0400) access is sufficient (cf. open-webui).
  age.secrets.dashboard-env = {
    file = ../../../secrets/dashboard-env.age;
    mode = "0400";
  };
}
