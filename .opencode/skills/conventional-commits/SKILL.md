---
name: conventional-commits
description: Commit staged and unstaged changes as conventional commits that match the repository's own conventions — survey repo state, discover the commit style from AGENTS.md/CLAUDE.md, review the diff for secrets, split into logical commits, and run the project's pre-commit checks. Use when the user asks to commit changes.
compatibility: opencode
---

# Conventional Commits

A repeatable, project-aware commit workflow. Never commit unless the user asks.

**Default commit message is exactly one line: `type(scope): title`. Nothing
else.** No body, no bullet lists, no blank-line-separated paragraphs, no
trailers of any kind — that means no `Co-authored-by`, no DCO signoff, no
"🤖 Generated with …" / "Generated with Claude Code" footer, no tool
signature. This is the default for every repo unless that repo's own
`AGENTS.md`/`CLAUDE.md`/`CONTRIBUTING.md` **explicitly** documents a
different house style (e.g. explanatory bodies or trailers) — silence means
single-line, it is never the permissive default. If your harness normally
appends a signature/co-author trailer to commits automatically, suppress it
here; it is not part of the message.

## 1. Survey the repo state

- `git status --short` — what is staged, unstaged, untracked?
- `git diff` and `git diff --cached` — what actually changed?
- `git log --oneline -10` — the house style of recent commits.

## 2. Discover the repo's conventions

Read `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, or any `git commit` template
before writing a message. Conventions that differ per repo:

- **Type set**: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`,
  `build`, `ci`, `revert`.
- **Scope** in parentheses: `feat(woodpecker): …` vs no scope.
- **Body policy**: single-line subjects only vs explanatory bodies and
  trailers (`Co-authored-by`, DCO signoff).
- **Case and punctuation** of the subject line.

Follow what the repo already does for type set, scope, and casing. Body
policy stays single-line (see above) unless the repo's own docs explicitly
say otherwise — a repo's silence on the topic is not permission to add one.

## 3. Security check the diff

Before anything is staged, scan the diff for:

- API keys, tokens, passwords, private keys, `.env` files.
- Accidental credentials in comments, logs, or config.
- Personal data that shouldn't be version-controlled.

If a secret is present, **stop and report it** — do not commit. Suggest the
gitignore entry and history scrub, but do not commit the secret.

## 4. Split into logical commits

- Group changes into cohesive commits: one concern per commit.
- Keep each commit buildable/verifiable on its own where practical.
- Stage deliberately with `git add <paths>` per logical unit; avoid
  `git add -A` when the working tree mixes unrelated changes.
- Untracked files the repo expects (`hardware-configuration.nix`,
  `flake.lock` updates) belong in the same commit as the change that needs
  them — stage them explicitly so `git status` ends clean.

## 5. Write the message

`type(scope): summary` — one line, imperative, ≤ ~72 chars, lower-case unless
a proper noun. The whole commit message. Example:

```
fix(cache): grant atticd secret access by group
```

Only add a body/trailer when the repo's own `AGENTS.md`/`CONTRIBUTING.md`
explicitly documents that convention (see the rule at the top of this file).
That is the exception, not the default — most repos get exactly one line.

## 6. Run pre-commit checks

If the project has hooks or a verify step (lefthook, pre-commit, `just fmt`,
CI gate), run them for the staged changes and fix failures **before**
committing. Commit through the repo's sanctioned path when one exists (e.g.
`nix develop -c git commit` when the repo's hooks depend on a dev shell).

If a hook rejects the commit:

- Fix the underlying issue, then create a **new** commit.
- Do not `--amend` an already-pushed commit, do not `--no-verify` to bypass
  hooks, and do not force-push.

## 7. Verify

After committing:

- `git log --oneline -3` — message matches the convention.
- `git status --short` — working tree reflects what you intended (clean, or
  only intentionally-left changes).

Then report the commit(s) to the user. Leave push and PR creation to an
explicit request.
