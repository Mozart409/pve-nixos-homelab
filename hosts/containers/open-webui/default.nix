{
  config,
  lib,
  pkgs,
  ...
}: {
  # open-webui ships under a non-free license
  nixpkgs.config.allowUnfree = true;

  # Open WebUI - LLM chat interface (external APIs only)
  # Served behind Caddy at the host root (see ../configuration.nix); the SPA's
  # build-time base path is "/", so it cannot live under a subpath.
  # Port 8088 because AlbyHub occupies 8080.
  services.open-webui = {
    enable = true;
    port = 8088;
    environment = {
      # Force env vars to always take precedence over database-stored config.
      # Without this, ConfigVar settings (web search, API endpoints) are read
      # from the SQLite DB on restart and env vars are silently ignored.
      ENABLE_PERSISTENT_CONFIG = "false";

      WEBUI_AUTH = "true";
      ENABLE_OLLAMA_API = "false";
      ENABLE_OPENAI_API = "true";
      # External URL used for OAuth redirects and absolute links.
      WEBUI_URL = "https://homelab-containers.dropbear-butterfly.ts.net";
      # CORS must list every origin used to reach the UI, or WebSockets break.
      CORS_ALLOW_ORIGIN = "https://homelab-containers.dropbear-butterfly.ts.net;https://containers.homelab.local";
      # Disable the local email/password signup form. Account creation is only
      # via OAuth (Pocket ID), which stays enabled below so group members can
      # still provision accounts on first login.
      ENABLE_SIGNUP = "false";
      # OIDC authentication
      ENABLE_OAUTH_SIGNUP = "true";
      OAUTH_PROVIDER_NAME = "Pocket ID";
      OPENID_PROVIDER_URL = "https://pocketid.dropbear-butterfly.ts.net/.well-known/openid-configuration";
      OAUTH_SCOPES = "openid email profile groups";
      ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
      OAUTH_ROLES_CLAIM = "groups";
      OAUTH_ADMIN_ROLES = "admins";
      # Web search via local SearXNG instance
      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "http://127.0.0.1:8089/search?q=<query>&format=json";
      # vLLM endpoint on wotan (OpenAI-compatible).
      # OPENAI_API_BASE_URLS is a semicolon-separated list. The first entry
      # is the standard OpenAI endpoint (key comes from OPENAI_API_KEY in the
      # env file); the second is the local vLLM instance. Open WebUI pads the
      # key list with empty strings when fewer keys than URLs are provided.
      # An empty key for vLLM means no Authorization header is sent, which
      # vLLM accepts by default (no --api-key set).
      # Note: custom endpoint names/tags cannot be set via env vars; they
      # live in the OPENAI_API_CONFIGS database table which is UI-managed.
      OPENAI_API_BASE_URLS = "https://api.openai.com/v1;http://wotan.homelab.local:10808/v1";
    };
    # Secrets file should contain:
    # OAUTH_CLIENT_ID=...
    # OAUTH_CLIENT_SECRET=...
    # OPENAI_API_KEY=sk-...  (optional)
    environmentFile = config.age.secrets.open-webui-env.path;
  };

  # Open WebUI secrets.
  # The open-webui service runs as a systemd DynamicUser, so there is no static
  # "open-webui" user/group to chown to. systemd reads EnvironmentFile as root
  # before dropping privileges, so root-only access is sufficient (cf. hermes).
  age.secrets.open-webui-env = {
    file = ../../../secrets/open-webui-env.age;
    mode = "0400";
  };
}
