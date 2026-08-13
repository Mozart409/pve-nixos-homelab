---
name: claude-code-permissions
description: Use when updating Claude Code permission guardrails on the development host — editing claude-permissions-data.nix, the allow/deny/defaultMode lists, dontAsk mode, or MCP allow rules for axon-gateway / internal-dashboard, then committing, deploying with just cah development and verifying ~/.claude/settings.json on the host.
---

# Claude Code Permissions on `development`

Claude Code runs unattended on the `development` host (`192.168.2.184`), so its
permission config is a guardrail, not a prompt. The source of truth is **not**
`~/.claude/settings.json` on the host — that file is mutable and partly
machine-written. Editing it by hand does not stick: `claude-permissions-apply`
jq-merges the three keys wholesale at boot, and `claude-settings-verify` pushes
a drift notification when they change.

## Source of truth

**`modules/claude-permissions-data.nix`** — plain data (`allow`, `deny`,
`defaultMode`), imported by exactly two consumers so they cannot drift:

| Module | Role |
| --- | --- |
| `modules/claude-permissions.nix` | Writer. `claude-permissions.service` (user unit) jq-merges the three keys into `~/.claude/settings.json` at boot. |
| `modules/claude-settings-verify.nix` | Checker. Confirms the rules survived; notifies `notify.iphone_von_amadeus` on drift. |

Both are imported by `hosts/development/configuration.nix`.

The three keys under `permissions`:
- `allow` — actions/tools granted without prompting.
- `deny` — blocked in every mode. **Precedence is `deny` > `ask` > `allow`.**
- `defaultMode` — `"dontAsk"`: anything unlisted is denied silently. That is the
  whole point: with nobody watching, a prompt is an indefinite hang. Never set
  it to a mode that prompts.

## Rule syntax

- `Tool(pattern)` — e.g. `Bash(git push:*)`. A trailing `*` is a prefix match;
  a compound command is refused unless EVERY segment is allowed.
- `Read(...)`, `Write(...)`, `Edit(...)` — file-path rules, also bound into the
  Bash engine (`cp .env.example .env` is refused via a Read deny on `**/.env`).
- MCP tools — `mcp__<server>__*` (server-level wildcard) or an exact
  `mcp__<server>__<tool>` name. Server/tool names keep hyphens; only characters
  outside `[a-zA-Z0-9_-]` become underscores.
  **A bare `mcp__*` allow rule is skipped by Claude Code with a warning and
  approves nothing.** Every server must be named explicitly.
- `AskUserQuestion` is effectively denied by `dontAsk`.

## Editing the allow/deny lists

1. Edit `modules/claude-permissions-data.nix` only. Keep the comment grouping —
   the grouping is the documentation.
2. Keep `AGENTS.md` §8 in sync — it mirrors the current MCP allow rules and the
   mode rationale.
3. Format and validate:
   - `just fmt` (alejandra; required before commit).
   - A **scoped per-host eval** for the touched hosts:
     `nix eval ".#nixosConfigurations.development.config.system.build.toplevel.drvPath"`.
     The full `just nixos-check` evaluates ~16 hosts and is slow; it stays the
     user's pre-merge gate.
4. Commit in repo style: single-line conventional commits, `feat(development):`
   for the data change, `docs(agents):` for the AGENTS.md update. Commit on a
   feature branch (`feat/<slug>`) and push to `origin` (Forgejo) — never `main`
   (branch-protected). Open the PR from the Forgejo compare URL.

## Deploy

```bash
just cah development          # = colmena apply --on development
```

`colmena apply` builds from the **local working tree**, so deploying while a
feature branch is checked out applies that branch's state. Expect
`Activation successful` and a `restarting ... claude-permissions.service` line
when the rules changed.

## Verify on the host

```bash
ssh development.homelab.local "systemctl --user status claude-permissions --no-pager | head -4"
ssh development.homelab.local "jq '.permissions.defaultMode' ~/.claude/settings.json"    # "dontAsk"
ssh development.homelab.local "jq '.permissions.allow[]' ~/.claude/settings.json | grep mcp__"
ssh development.homelab.local "jq '.permissions.deny | length' ~/.claude/settings.json"  # 68
```

Then run the drift verifier end-to-end — it must print
`claude settings OK on homelab-development`:

```bash
ssh development.homelab.local "systemctl --user start claude-settings-verify && journalctl --user -u claude-settings-verify -n 3 --no-pager"
```

A non-OK result means the boot-time apply did not stick and a drift
notification is on its way to `notify.iphone_von_amadeus`.

## Gotchas

- A rule typo'd to match no known tool warns at startup but does not fail;
  under `dontAsk` the symptom is a silently-refused tool, so verify the exact
  names in `~/.claude/settings.json` after deploy.
- `moshi-hook-setup.service` / `herdr-setup.service` rewrite other keys in
  settings.json at boot; `claude-permissions.service` runs after them so the
  permissions block is the last word each boot.
- Restarting a service never re-applies the rules; only a new activation (or
  manually starting `claude-permissions.service`) does.
