---
name: subagent-driven-development
description: Execute a multi-step implementation plan by dispatching a fresh subagent per task and running a two-stage review (spec compliance, then code quality) before each task is marked done. Use when executing an implementation plan with independent tasks, implementing a feature broken into several tasks, or parallelizing coding work across subagents. Do not use for tiny single-file changes where subagent overhead outweighs the benefit.
compatibility: opencode
---

# Subagent-Driven Development

**Core principle:** fresh subagent per task + two-stage review (spec then quality)
= high quality, fast iteration, no context pollution.

Run tasks in the **same session** as the controller. Do not open a parallel
session and do not let subagents read the plan file themselves — the controller
curates exactly what context each subagent needs.

## The Process

### 1. Read the plan and build the task list

- Read the plan document end-to-end.
- Extract every task with its **full text**, not a reference to it.
- Note the context each task needs (surrounding modules, conventions, prior
  tasks it depends on).
- Create a `TodoWrite` list with one item per task. This is the single source
  of progress truth.

### 2. Dispatch one implementer subagent per task

Use the `task` tool with a **self-contained prompt**. Never tell a subagent to
"read the plan file" — paste the task text plus scene-setting context:

- The task's full text and its acceptance criteria.
- Where the task fits: files to touch, modules involved, related code.
- Project conventions the subagent must follow (lint/test commands, style).
- The verification command to prove the task works (`just nixos-check`,
  `pytest`, `cargo test`, …).
- "Implement this, run the verification, and report back what changed, the
  tests you ran, and any questions."

Let the subagent implement, test, and self-review before it returns.

### 3. Two-stage review after every task

Dispatch **two reviewer subagents in this exact order**:

1. **Spec compliance reviewer** — checks the implementation matches the task's
   acceptance criteria exactly: everything asked for implemented, nothing
   extra, interfaces correct.
2. **Code quality reviewer** — checks security, performance, maintainability,
   and test coverage.

Hand each reviewer the task text, the list of changed files/commits (git SHAs),
and what "done" means. A reviewer subagent should be read-only: ask it to report
findings, not fix them.

### 4. Close the loop

- **Spec or quality issues found?** Send the findings back to the **same**
  implementer (resume the subagent session with its `task_id`) and have it fix
  them, then re-review. Repeat until the reviewer approves. Never proceed with
  open issues.
- **Approved?** Mark the task complete in `TodoWrite` and move to the next.

### 5. Final review

When all tasks pass, dispatch one final code reviewer for the **entire
implementation** — cross-task integration, consistency, and full test suite —
before declaring the work done.

## Prompt templates

### Implementer

```
Implement the following task.

TASK (full text):
<task text + acceptance criteria>

CONTEXT:
- Files to touch: <paths>
- Related code to read first: <paths>
- Conventions: <lint/test/style requirements>

VERIFY:
Run <verification command> and make sure it passes before you return.

Report back: files changed, tests run + results, a self-review of anything
you're unsure about, or any questions you need answered first.
```

### Spec compliance reviewer

```
Review whether this implementation matches the spec EXACTLY.

SPEC:
<task text + acceptance criteria>

CHANGES (git SHAs):
<commits or diff range>

Verdict: COMPLIANT, or list every gap between spec and implementation
(missing behavior, extra/unrequested behavior, wrong interfaces). Do not edit
any files — report only.
```

### Code quality reviewer

```
Review the code quality of this implementation.

CHANGES (git SHAs):
<commits or diff range>

Focus on: security, performance, maintainability, error handling, test
coverage. Label each finding BLOCKING / IMPORTANT / NIT.

Verdict: APPROVED or a list of findings. Do not edit any files — report only.
```

## Red flags

**Never:**

- Skip either review stage (spec OR quality).
- Start the quality review before the spec review passes — wrong order.
- Dispatch multiple implementers in parallel for overlapping files (conflicts).
- Make the subagent read the plan file (provide the full task text instead).
- Skip scene-setting context (the subagent needs to know where the task fits).
- Ignore subagent questions — answer them before letting the subagent proceed.
- Accept "close enough" on spec compliance.
- Let the implementer's self-review replace the real reviews.
- Move to the next task while either review has open issues.
- Try to fix a failed task in the controller context — dispatch a fix subagent
  instead (avoids context pollution).

## When to use a plain single agent instead

Skip this workflow when the change is one small, tightly-coupled unit that a
single agent can finish quickly. The subagent dispatch + two-review overhead
only pays for when there are genuinely independent tasks.
