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
        type = "searxng";
        url = "https://searxng.dropbear-butterfly.ts.net";
      };
      weather = {
        latitude = 48.1374;
        longitude = 11.5755;
        location = "Munich";
      };
      hofvarpnir.url = "https://hofvarpnir.homelab.local";
      quick_links = [
        {
          name = "UniFi";
          url = "https://192.168.2.142:8443";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/ubiquiti-unifi.svg";
        }
        {
          name = "Proxmox";
          url = "https://pve-gigabyte.dropbear-butterfly.ts.net/";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/proxmox.svg";
        }
        {
          name = "Open WebUI";
          url = "https://homelab-containers.dropbear-butterfly.ts.net/";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/open-webui.svg";
        }
        {
          name = "Grafana";
          url = "https://homelab-otel.dropbear-butterfly.ts.net/grafana";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/grafana.svg";
        }
        {
          name = "Prometheus";
          url = "http://192.168.2.135:9090";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/prometheus.svg";
        }
        {
          name = "Forgejo";
          url = "https://homelab-forgejo.dropbear-butterfly.ts.net/";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/forgejo.svg";
        }
        {
          name = "Harbor";
          url = "https://homelab-harbor.dropbear-butterfly.ts.net/";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/harbor.svg";
        }
        {
          name = "Jellyfin";
          url = "https://jellyfin.homelab.local/web/#/home";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/jellyfin.svg";
        }
        {
          name = "Home Assistant";
          url = "https://homeassistant.dropbear-butterfly.ts.net/lovelace/0";
          icon = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/home-assistant.svg";
        }
        {
          name = "Hofvarpnir";
          url = "https://hofvarpnir.homelab.local/dashboard";
          icon = "https://raw.githubusercontent.com/Mozart409/hofvarpnir/refs/heads/main/crates/hof-web/assets/logo.png";
        }
      ];
      health_checks = [
        {
          name = "Router";
          url = "http://192.168.2.1";
        }
        {
          name = "step-ca";
          url = "https://ca.homelab.local:8443/health";
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
          url = "https://homelab-otel.dropbear-butterfly.ts.net/grafana/api/health";
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
          url = "https://hermes.homelab.local/health";
        }
        {
          name = "RomM";
          url = "https://romm.homelab.local";
        }
        {
          name = "Axon Gateway";
          url = "https://axon.homelab.local/health";
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
