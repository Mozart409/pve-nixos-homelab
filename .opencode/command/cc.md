---
description: Conventional commit(s) in the user's style — type(scope): lowercase summary, no body.
agent: build
---

Commit the current working-tree changes as conventional commit(s) in the user's style.

## Workflow

1. **Survey the state.** Run `git status`, `git diff`, `git diff --cached`, and `git log --oneline -10` (to match the repo's existing type/scope usage).
2. **Analyze and group.** Read every diff carefully. Group changed files into logical commits by shared intent — the same feature, the same bug fix, the same concern. Do NOT force everything into a single commit, and do NOT split one coherent change across commits.
3. **Commit each group** as its own commit, one at a time:
   - `git add <files>` for that group only (never `git add -A` blindly, never stage files from another group)
   - `git commit -m "<message>"`
   - If a commit fails (hooks, linters, cog verify), fix the message or the staged set and retry with a fresh commit — never amend.
4. **Leave nothing behind.** Every changed file must end up in exactly one commit. Skip files you cannot group confidently (e.g. editor droppings) and say so, rather than committing clutter.

## Commit message rules (STRICT)

- Format: `type(scope): summary`
- `type` — one of: `feat`, `fix`, `refactor`, `chore`, `docs`, `ci`, `build`, `perf`, `test`, `style`, `release`
- `scope` — optional, a single **lowercase** word naming the subsystem (e.g. `dns`, `harbor`, `acl`, `readme`). Omit when nothing fits.
- `summary` — lowercase, imperative, short, simple, plain. No trailing period. No emojis. No markdown.
- **NO BODY. Title only, single line.** This is non-negotiable — the whole message is the subject line.
- If the repo has a commit-lint hook (`cog verify`, commitlint), run `git commit` normally so the hook verifies your message.

Good:
- `fix(dns): allow tailnet clients in unbound access-control`
- `feat: add hyprland plugins`
- `chore: remove obsolete configs`
- `refactor(disko): move to xfs layout`

Bad:
- `fix: fix bug` (redundant "fix")
- `Feat(DB): Add Postgres | Add features` (wrong case, multiple subjects, body-like separator)
- `feat: implement foo\n\nThis also...` (has a body — never)

## Arguments

If `$ARGUMENTS` was provided, treat it as intent for the commit(s) — e.g. a suggested type, scope, or a directive like "wip", "just one commit", or "squash everything". Otherwise infer grouping, types, and scopes yourself from the diff.

## Style guide for grouping

- A small set of files fixing one thing → one `fix(scope):`.
- A dependency bump or tooling change → `chore:` or `build:`.
- Config that documents things → `docs:`.
- A rename/restructure that changes no behavior → `refactor:`.
- Infrastructure/tooling in the repo (CI, Terraform, Nix modules) → `ci:`/`chore:` with the relevant scope.

When done, report the commit(s) you made with a one-line summary of each.
