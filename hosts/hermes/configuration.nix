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
    ../../modules/osquery.nix
  ];

  networking.hostName = "homelab-hermes";

  # Static IP configuration
  networking.interfaces.ens18 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.2.155";
        prefixLength = 24;
      }
    ];
  };
  networking.defaultGateway = "192.168.2.1";

  # Node exporter for Prometheus monitoring
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd" "processes"];
  };

  # OpenCode Zen provider key. To activate opencode-zen as the named provider,
  # re-key this file to contain OPENCODE_ZEN_API_KEY=... (currently holds the
  # legacy OPENAI_API_KEY/OPENAI_BASE_URL from the old custom-provider setup).
  age.secrets.hermes-opencode-zen-key = {
    file = ../../secrets/hermes-opencode-zen-key.age;
    mode = "0400";
  };

  # API server key for hermes-agent
  age.secrets.hermes-api-server-key = {
    file = ../../secrets/hermes-api-server-key.age;
    mode = "0400";
  };

  # DeepSeek provider key (file contains DEEPSEEK_API_KEY=...)
  age.secrets.hermes-deepseek-key = {
    file = ../../secrets/hermes-deepseek-key.age;
    mode = "0400";
  };

  # Hermes Agent - Native mode with security hardening
  services.hermes-agent = {
    enable = true;

    # Load provider keys from secrets (files contain KEY=value format).
    # Both providers' keys are loaded so the active provider can be switched
    # via settings.provider below without touching secrets.
    environmentFiles = [
      config.age.secrets.hermes-opencode-zen-key.path
      config.age.secrets.hermes-deepseek-key.path
      config.age.secrets.hermes-api-server-key.path
    ];

    # API server config (not secrets). Named providers carry their own
    # base_url, so OPENAI_BASE_URL is no longer needed.
    environment = {
      API_SERVER_ENABLED = "true";
      # hermes API server default port; Caddy reverse_proxy targets this.
      API_SERVER_PORT = "8642";
    };

    # Declarative configuration. The API server uses this single configured
    # provider/model (the model field Open WebUI sends is ignored for routing).
    # Switch providers by changing provider/model here and redeploying.
    settings = {
      # DeepSeek (uses DEEPSEEK_API_KEY, base_url https://api.deepseek.com/v1).
      # Alt: provider = "opencode-zen"; model = "minimax-m2.5"; (needs
      # OPENCODE_ZEN_API_KEY in hermes-opencode-zen-key.age).
      provider = "deepseek";
      model = "deepseek-chat";

      # External memory provider: Holographic — fully local, no deps/infra.
      # Stores facts in a local SQLite FTS5 DB at $HERMES_HOME/memory_store.db.
      # NumPy (added via extraPythonPackages below) enables HRR algebra
      # (probe/reason compositional queries).
      memory.provider = "holographic";
      plugins.hermes-memory-store = {
        # Auto-extract facts from the conversation at session end.
        auto_extract = true;
        default_trust = 0.5;
      };
    };

    # NumPy enables Holographic's HRR algebra (probe/reason). Matches the
    # agent's Python 3.12 env.
    extraPythonPackages = [pkgs.python312Packages.numpy];

    # System prompt and user context
    documents = {
      "SOUL.md" = ''
        # Hermes - Homelab Assistant

        You are Hermes, an AI assistant for managing a NixOS-based homelab.
        You have access to Home Assistant for smart home control.

        ## Capabilities
        - Control smart home devices via Home Assistant MCP
        - Answer questions about the homelab infrastructure
        - Help with automation tasks

        ## Guidelines
        - Be concise and helpful
        - Confirm before taking actions that affect physical devices
        - Report errors clearly
      '';
      "USER.md" = ''
        # User Context

        The user manages a Proxmox-based homelab running NixOS VMs.
        Infrastructure includes: database, monitoring (otel), DNS, UniFi controller,
        containers, and various MCP services.

        Network: 192.168.2.0/24
        Tailnet: dropbear-butterfly.ts.net
      '';
    };

    # MCP Servers - Home Assistant integration.
    # Use the local DNS name (homelab DNS + step-ca TLS, trusted via
    # step-ca-trust.nix) — the Tailscale MagicDNS name does not resolve
    # from this host.
    mcpServers = {
      homeassistant = {
        url = "https://mcp.homelab.local/mcp";
        # No auth required currently
      };
    };

    # Keep CLI available for debugging
    addToSystemPackages = true;
  };

  # Ensure hermes starts after secrets are available
  systemd.services.hermes-agent = {
    wants = ["agenix.target"];
    after = ["agenix.target" "tailscaled.service"];
  };

  # Caddy reverse proxy - Tailscale-only access
  services.caddy = {
    enable = true;

    # Tailscale hostname
    virtualHosts."homelab-hermes.dropbear-butterfly.ts.net" = {
      extraConfig = ''
        tls {
          get_certificate tailscale
        }

        handle {
          reverse_proxy http://localhost:8642
        }
      '';
    };

    # Local network hostname with step-ca certificate
    virtualHosts."hermes.homelab.local" = {
      extraConfig = ''
        tls {
          ca https://ca.homelab.local:8443/acme/acme/directory
        }

        handle {
          reverse_proxy http://localhost:8642
        }
      '';
    };
  };

  # Allow Caddy to get Tailscale certs
  services.tailscale.permitCertUid = "caddy";

  # Give Caddy access to Tailscale socket for cert fetching
  systemd.services.caddy = {
    after = ["tailscaled.service"];
    wants = ["tailscaled.service"];
    serviceConfig.BindPaths = ["/run/tailscale/tailscaled.sock"];
  };

  # Strict firewall - Tailscale only, no LAN exposure
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    # Only allow SSH and node exporter on LAN (for initial setup and monitoring)
    allowedTCPPorts = [
      22 # SSH
      443 # HTTPS
      9100 # Node exporter
    ];
    # Block all other LAN access - hermes web UI only via Tailscale
  };

  environment.systemPackages = with pkgs; [
    # Minimal tools for debugging
    jq
    curl
  ];
}
