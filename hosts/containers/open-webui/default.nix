{
  config,
  lib,
  pkgs,
  ...
}: {
  # open-webui ships under a non-free license
  nixpkgs.config.allowUnfree = true;

  # Open WebUI - LLM chat interface (external APIs only)
  # Served behind Caddy at /open-webui (see ../configuration.nix).
  # Port 8088 because AlbyHub occupies 8080.
  services.open-webui = {
    enable = true;
    port = 8088;
    environment = {
      WEBUI_AUTH = "true";
      ENABLE_OLLAMA_API = "false";
      ENABLE_OPENAI_API = "true";
      # OIDC authentication
      ENABLE_OAUTH_SIGNUP = "true";
      OAUTH_PROVIDER_NAME = "Pocket ID";
      OPENID_PROVIDER_URL = "https://pocketid.dropbear-butterfly.ts.net/.well-known/openid-configuration";
      OAUTH_SCOPES = "openid email profile groups";
      ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
      OAUTH_ROLES_CLAIM = "groups";
      OAUTH_ADMIN_ROLES = "admins";
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
