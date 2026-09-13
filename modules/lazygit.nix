{...}: {
  # Home-manager module: lazygit with background fetching OFF.
  #
  # lazygit's default `git.autoFetch = true` runs `git fetch` every 60 s for as
  # long as the TUI is open. On 2026-09-13 two idle lazygit panes on the
  # development host (herdr workspaces for nixos-ventara-ai and
  # homelab-mcp-servers) were the source of ~2,900 SSH logins a day on Forgejo
  # -- every one an fsync'd `public_key.updated_unix` write on Forgejo's local
  # Postgres, taking 0.2-3 s each on the saturated HDD mirror. `f` still
  # fetches on demand; modules/repo-sync.nix already sweeps every repo under
  # ~/code on a 20 min timer, so nothing is lost.
  programs.lazygit = {
    enable = true;
    settings.git.autoFetch = false;
  };
}
