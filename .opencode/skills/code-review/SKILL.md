---
name: code-review
description: Perform a structured, severity-labeled code review of a diff, branch, or pull request — determine scope, then run correctness, security, performance, and maintainability passes, and end with a ship-or-iterate verdict. Use when the user asks to review uncommitted changes, a feature branch, or a PR.
compatibility: opencode
---

# Structured Code Review

Review like a senior engineer: structured, consistent, and grounded in the
actual diff — not vague suggestions. Work in four phases and always end with a
clear verdict.

## Phase 1 — Determine scope

- **Uncommitted changes:** review `git diff` (staged + unstaged).
- **Branch or PR:** review `git diff <base>...<branch>` (three-dot: changes on
  the branch only).
- Identify what the change is meant to do: read the PR/commit description, or
  infer intent from the touched files and test changes.
- **Pre-existing code is exempt.** Only findings about the code being changed
  belong in the review. Do not file unrelated cleanup as findings.

## Phase 2 — Review passes

Run these in order. Cover the whole diff in every pass — do not stop after the
first issue found.

### Correctness
- Does the change actually do what it claims? Edge cases, error paths, and
  failure handling.
- Resource management: connections, files, locks, goroutines/subprocesses
  cleaned up on all exits.
- Concurrency: races, shared mutable state, cancellation.
- Does existing behavior change unintentionally?

### Security (first-class, every review)
- **Exposed secrets**: hardcoded keys, tokens, credentials, `.env` files, or
  anything secret-looking added to the diff. Flag `BLOCKING`.
- Injection: SQL, shell, command, path traversal, XSS, template injection.
- AuthN/AuthZ: new endpoints or actions missing authentication or
  authorization checks.
- Trust of untrusted input: is user input validated at the boundary?
- If nothing security-relevant changed, say so explicitly rather than
  skipping the pass.

### Performance
- Obvious N+1, quadratic loops, or re-computation in hot paths.
- Unbounded growth: caches, logs, result sets.
- Note only what the change introduces or makes worse; premature optimization
  of untouched code is out of scope.

### Maintainability
- Clear naming, single responsibility, no duplicated logic.
- Error messages and logs that are actionable.
- Tests: do they cover the business logic and the new behavior? Trust
  well-tested library code; focus coverage where the change adds behavior.

## Phase 3 — Label every finding

| Label | Meaning |
| --- | --- |
| `BLOCKING` | Must fix before merge — security hole, broken behavior, data loss. |
| `IMPORTANT` | Should fix — clear bug or maintainability problem, workaround exists. |
| `NIT` | Style or minor clarity; safe to defer. |
| `SUGGESTION` | Alternative approach worth considering, not required. |
| `PRAISE` | Something done well — call it out; it anchors the review's tone. |

Order findings by severity, most severe first. Reference exact file paths and
line numbers.

## Phase 4 — Deliver the verdict

End with one of:

- **Ship** — no `BLOCKING`, no open `IMPORTANT` findings.
- **Iterate** — at least one `BLOCKING` or unresolved `IMPORTANT` finding.
  List what must change to reach ship.

Keep the tone collaborative: questions over commands, suggestions over
mandates.

## Large diffs

For big changes, split the review:

- Group the diff by area (schema, API, UI, infra) and review each separately.
- Optionally dispatch parallel reviewer subagents per area and synthesize their
  findings into a single report (see `orchestrate-subagents`).
- Never claim a diff reviewed without covering every changed file.

## Security-specific checklist

Reuse this as a quick scan on every review:

- [ ] No secrets or credentials in the diff.
- [ ] No new injection surface (shell, SQL, HTML, path).
- [ ] New endpoints/actions protected by authN/authZ.
- [ ] Untrusted input validated at the boundary.
- [ ] Errors don't leak internals (stack traces, file paths, versions).
