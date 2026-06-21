---
name: obsidian-vault-notes
description: Create daily notes, shopping lists, to-dos, and general notes in the shared Obsidian vault with conventional commits. Designed for voice-or-text quick entry.
platforms: [linux]
required_environment_variables:
  - OBSIDIAN_VAULT_PATH
required_commands:
  - git
---

# Obsidian Vault Notes

Use this skill when the user asks you to save anything in the shared Obsidian vault — a daily note, shopping list, todo list, or general note. Follow all steps below for every vault write.

## Vault path

Resolve `OBSIDIAN_VAULT_PATH` from the environment. If unset, fall back to `/var/lib/hermes/workspace/vault` (the homelab default). Use the resolved absolute path throughout.

## Pre-write context gathering

Before creating any note, gather context so you don't make incorrect claims:

1. Search the vault for existing notes on the topic with `search_files(pattern="<topic>", path="<vault_path>", file_glob="*.md", target="content")`.
2. Search recent session history with `session_search(query="<topic>")` for relevant discussion.
3. Check the filesystem for any related project artifacts (e.g. `search_files(pattern="<project_name>", path=".", target="files")`).
4. Only write claims you can verify from the above sources. If uncertain, note the uncertainty in the note.

## Note types and workflows

### Daily Note

For open-ended day notes, journal entries, or log entries.

1. **Name the file** `YYYY-MM-DD.md` (today's date, e.g. `2026-06-21.md`).
2. **Check if it already exists** — if so, append to it instead of overwriting.
3. **Structure**: Use the template structure from `Template.md` if it exists in the vault:
   - YAML frontmatter with `created`, `updated`, and `tags`
   - Sections: ## Todos, ## Notes, ## Shopping List, ## Other
   - Remove unused sections. Add new sections if needed.
4. **Write** with `write_file` at `<vault_path>/YYYY-MM-DD.md`.
5. **Commit** with `git commit -m "docs(vault): add YYYY-MM-DD note"` in the vault directory.

### Shopping List

For grocery/supply lists (e.g. DM, Rewe, Amazon).

1. **Name the file** `YYYY-MM-DD.md` (the date the list is for, often today or tomorrow).
2. **Check if it already exists** — if so, append items to the Shopping List section.
3. **Structure**: YAML frontmatter + ## Shopping List with checkbox items.
4. **Location convention**: Specify the store as a sub-heading, e.g. `### DM (Drogerie Markt)` — or just list destinations. DO NOT second-guess what specific products a store (like DM) sells. Store names like "DM" = German Drogerie Markt destinations, not product names. List what the user tells you.
5. **Write** with `write_file` or `patch` (for append).
6. **Commit** with `git commit -m "docs(vault): add shopping list for YYYY-MM-DD"`.

### Todo / Task List

For a set of tasks (one-off lists, not daily).

1. **Name the file** `YYYY-MM-DD.md` or a descriptive name like `project-tasks.md`.
2. **Structure**: YAML frontmatter + ## Todos with checkbox items.
3. **Write** with `write_file`.
4. **Commit** with `git commit -m "docs(vault): add todo list for <topic>"`.

### General Note

For reference info, meeting notes, ideas, or anything else.

1. **Choose a descriptive filename** like `topic-name.md`.
2. **Structure**: YAML frontmatter + sections appropriate to the content.
3. **Write** with `write_file`.
4. **Commit** with `git commit -m "docs(vault): add <topic> note"`.

## Git commit rules (must follow every time)

- The vault has a systemd service that auto-pulls/pushes. **NEVER push from the sandbox.**
- Always `cd <vault_path>` and run `git add -A` then `git commit`.
- Use conventional commit format: `docs(vault): <message>`
- Imperative mood, lowercase, no trailing period. Example:
  - `docs(vault): add shopping list for 2026-06-21`
  - `docs(vault): add notes on tailscale networking`
- Breaking changes use `docs(vault)!: <message>` or the `BREAKING CHANGE:` footer.

## Pitfalls

- **Never push.** The systemd service handles that. Pushing from the sandbox will conflict.
- **Always check if a file already exists** before creating it. Use `search_files(target="files")` or `read_file` to probe.
- **Template is read-only.** Copy it, don't move or modify it.
- **Don't over-search DM products.** "DM" means the destination (Drogerie Markt), not a product catalog.
- **Vault path may contain spaces.** Use file tools (write_file, read_file) which handle that, not shell commands with unquoted paths.
