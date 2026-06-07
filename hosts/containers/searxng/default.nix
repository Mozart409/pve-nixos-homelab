{
  config,
  lib,
  pkgs,
  ...
}: {
  # SearXNG - privacy-friendly metasearch engine for Open WebUI web search
  services.searx = {
    enable = true;
    redisCreateLocally = true;
    # Secret key for form validation / CSRF protection.
    # Stored in nix store is acceptable for a localhost-only instance.
    environmentFile = pkgs.writeText "searxng-env" "SEARXNG_SECRET=searxng-local-homelab-secret-2025";
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = 8089;
      };
      search = {
        # JSON format required for Open WebUI integration
        formats = [
          "html"
          "json"
        ];
      };
    };
  };
}
