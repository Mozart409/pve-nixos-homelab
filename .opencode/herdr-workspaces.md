# Herdr Workspaces

## Common Workspaces

| # | Label | Workspace ID | CWD |
|---|---|---|---|
| 1 | pve-nixos-homelab | w2N | `~/code/pve-nixos-homelab` |
| 2 | pve-nixos-homelab | w2P | `~/code/pve-nixos-homelab` |
| 3 | nixos-ventara-ai | w2S | `~/code/nixos-ventara-ai` |
| 4 | surrealdb-engram | w2T | `~/code/rust/surrealdb-engram` |

## Notes

- Workspace IDs are stable handles but may change across server restarts. Use `herdr workspace list` to discover current IDs.
- The `HERDR_ENV` env var is **not** propagated to all child processes (e.g. opencode's bash tool). The `herdr` CLI still works via socket IPC. Do not gate Herdr operations on `test "${HERDR_ENV:-}" = 1` when running from an opencode subagent — check `herdr workspace list` instead.
