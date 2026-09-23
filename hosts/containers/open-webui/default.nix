{
  config,
  lib,
  pkgs,
  ...
}: {
  # open-webui ships under a non-free license
  nixpkgs.config.allowUnfree = true;

  # Work around a broken test suite in `frictionless`, a transitive dependency
  # of open-webui (open-webui → sentence-transformers → phonemizer → segments →
  # csvw → frictionless). After the 2026-07 flake upgrade its pytest suite fails
  # (charset-detection tests assert e.g. `cp1252 == iso8859-1`, plus one
  # network-dependent remote-loader test), which aborts the whole `containers`
  # build. These are upstream test-environment issues, not real defects, so we
  # skip frictionless's check phase. Revisit once nixpkgs fixes the tests.
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions =
        prev.pythonPackagesExtensions
        ++ [
          (pyfinal: pyprev: {
            frictionless = pyprev.frictionless.overridePythonAttrs (_: {
              doCheck = false;
            });
          })
        ];
    })
  ];

  # Open WebUI - LLM chat interface (external APIs only)
  # Served behind Caddy at the host root (see ../configuration.nix); the SPA's
  # build-time base path is "/", so it cannot live under a subpath.
  # Port 8088 because AlbyHub occupies 8080.
  services.open-webui = {
    enable = true;
    port = 8088;
    environment = {
      # The upstream unit sets no HOME, and a post-flake-bump Open WebUI calls
      # `os.path.expanduser("~")` during startup. With HOME unset that returns
      # the literal "~", and it aborts with
      #   RuntimeError: Could not determine home directory
      # taking the whole service down. Point it at the state dir it already owns.
      HOME = "/var/lib/open-webui";

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
      # No account creation at all, by either path. Until 2026-09-14 any
      # Pocket ID account could
      # self-provision on first login; now only accounts that already exist
      # AND carry the `admins` group can sign in. To add a person: put them
      # in `admins` in Pocket ID, flip ENABLE_OAUTH_SIGNUP to "true" for one
      # deploy so their first login creates the account, flip it back.
      ENABLE_SIGNUP = "false";
      ENABLE_OAUTH_SIGNUP = "false";
      # OIDC authentication
      OAUTH_PROVIDER_NAME = "Pocket ID";
      OPENID_PROVIDER_URL = "https://pocketid.dropbear-butterfly.ts.net/.well-known/openid-configuration";
      OAUTH_SCOPES = "openid email profile groups";
      ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
      OAUTH_ROLES_CLAIM = "groups";
      OAUTH_ADMIN_ROLES = "admins";
      # Login is refused unless the groups claim contains one of these.
      OAUTH_ALLOWED_ROLES = "admins";
      # Web search via local SearXNG instance
      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "http://127.0.0.1:8089/search?q=<query>&format=json";
      # OpenAI-compatible endpoints. OPENAI_API_BASE_URLS is a semicolon-
      # separated list mapped positionally to OPENAI_API_KEYS (set in the
      # secrets env file). Open WebUI pads the key list with empty strings
      # when fewer keys than URLs are provided.
      #   1. wotan vLLM   — empty key (vLLM runs without --api-key).
      # `https://hermes.homelab.local/v1` was the 2nd entry until the 2026-09
      # hermes rebuild (docs/plans/hermes-rebuild.md §12): that host no longer
      # runs an api_server at all -- it is reached as an interactive agent over
      # ssh/mosh and its own OIDC-gated dashboard, not as a model backend. The
      # matching 2nd entry in OPENAI_API_KEYS (the hermes API_SERVER_KEY) is
      # gone with it; leaving the URL here would give Open WebUI a dead backend.
      # Note: custom endpoint names/tags cannot be set via env vars; they
      # live in the OPENAI_API_CONFIGS database table which is UI-managed.
      OPENAI_API_BASE_URLS = "http://wotan.homelab.local:10808/v1";
    };
    # Secrets file should contain:
    # OAUTH_CLIENT_ID=...
    # OAUTH_CLIENT_SECRET=...
    # OPENAI_API_KEYS=
    #   Semicolon-separated, positional to OPENAI_API_BASE_URLS above:
    #   a single empty entry (wotan vLLM runs without --api-key).
    environmentFile = config.age.secrets.open-webui-env.path;
  };

  # Open WebUI secrets.
  # The open-webui service runs as a systemd DynamicUser, so there is no static
  # "open-webui" user/group to chown to. systemd reads EnvironmentFile as root
  # before dropping privileges, so root-only access is sufficient.
  age.secrets.open-webui-env = {
    file = ../../../secrets/open-webui-env.age;
    mode = "0400";
  };
}
