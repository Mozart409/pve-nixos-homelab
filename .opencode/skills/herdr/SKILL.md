---
name: herdr
description: Use whenever the user asks anything about Herdr — the terminal workspace manager for AI coding agents running on this host (config, keybindings, or controlling panes/tabs/workspaces/agents from inside a Herdr-managed session).
compatibility: opencode
---

# Herdr

The installed `herdr` binary is the authority on its own current CLI and
control instructions — no copy is kept here, since it would go stale every
time `herdr` is upgraded (see the `herdr` flake input and `modules/herdr.nix`).

Run:

```bash
herdr --skill
```

and follow the printed instructions.
