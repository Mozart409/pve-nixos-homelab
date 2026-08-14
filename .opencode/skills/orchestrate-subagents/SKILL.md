---
name: orchestrate-subagents
description: Decide whether and how to delegate work to subagents — when delegation actually pays off, synchronous vs background, one task vs parallel tasks vs sequential chains, fresh vs resumed context, and which subagent role to pick. Use when considering delegating any non-trivial chunk of work or managing multiple subagents. Do not use to justify delegation for small work you should just do.
compatibility: opencode
---

# Orchestrating Subagents

Delegation has a coordination cost. Before delegating anything, decide whether
separation actually helps. If it does, decide how.

## 1. Whether to delegate at all

Use a subagent when the task has a clear boundary **and** separation provides a
concrete benefit:

- **Parallelism** — independent areas can be investigated, implemented, or
  reviewed at the same time.
- **Background progress** — broad or slow work continues while the main
  conversation does something else.
- **Role specialism** — a reviewer provides read-only critique focused on
  correctness, security, and maintainability; an explorer maps unfamiliar
  code before edits begin.

Do the work yourself when it is small, strictly sequential, needs clarification,
depends on nuanced user intent, or is mainly synthesis. **Do not delegate merely
because a subagent could do the same steps** — without parallelism or background
progress, the handoff overhead usually isn't worth it.

## 2. Pick the role

| Role | opencode agent | Use for |
| --- | --- | --- |
| Scout | `explore` | Reconnaissance: map the codebase, find where a change lands, surface risks. Read-only. |
| Implementer | `build` | Bounded implementation of a well-specified slice, with verification. |
| Analyzer | `general` | Research, comparison, or synthesis questions spanning many files. |
| Reviewer | `general` or `explore` | Independent read-only critique of a diff, plan, or design. |
| Planner | `plan` | Produce a plan/design doc before implementation starts. |

Do not use a scout or implementer to avoid ordinary parent-agent work. If the
parent can inspect, decide, or edit directly with less coordination overhead,
keep the work in the parent.

## 3. Choose the shape

- **One task** — a single bounded delegation: one review pass, one focused
  investigation, one implementation slice.
- **Parallel tasks** — independent pieces that can run concurrently. Each task
  must stand on its own with a distinct area or question. Avoid overlap unless
  it is intentional.
- **Chain** — later steps build on earlier subagent output. Prefer parallel
  tasks when the work is independent; use a chain when each step needs the
  previous step's result.

## 4. Choose the context

- **Fresh** (default) — the subagent works from a clean context and relies only
  on the prompt plus files it reads. Prefer this for broad scans, neutral
  investigation, and avoiding conversational baggage.
- **Resume** (`task_id`) — continue one exact previous subagent session. Use it
  for the fix-after-review loop: the implementer that built the code gets the
  reviewer's findings and iterates in its own session.
- **Inherit** (a rich prompt carrying live context) — only when the current
  conversation contains important context the child must have. Be deliberate:
  copy the needed facts into the prompt rather than dumping the whole
  conversation.

## 5. Write self-contained prompts

Subagents see only the prompt and the files they read. Every prompt must
include:

- **Goal** — what to accomplish, not how.
- **Scope** — files/modules to touch or read, and anything explicitly out of
  scope.
- **Boundary conditions** — conventions, required verification commands, and
  what "done" means.
- **Output contract** — the exact shape of the result: findings, file list,
  tests run, verdict.

Vague delegation like "look into the bug" or "work on tests" produces
overlapping, unverifiable work.

## 6. Synchronous vs background

- **Synchronous** — the delegated task is bounded and you need its result
  before answering. Default for small fan-outs, focused reviews, and quick
  investigations.
- **Background** — the work is broad, slow, long-running, or useful to start
  while the conversation continues. Long-running work is only a delegation
  reason when background progress helps — a long synchronous subagent just
  moves the waiting elsewhere.

## 7. Synthesize results

After subagents return:

- Merge overlapping findings; call out conflicts or uncertainty explicitly.
- Keep exact file names and line ranges when useful.
- Turn child output into a clear recommendation or next step.
- Never trust a subagent result blindly: verify integration yourself with the
  project's checks before claiming the work is done.

## Failure handling

- If a subagent fails, inspect the failure reason before deciding next steps.
- For a sync timeout, choose a longer timeout, a background rerun, or doing the
  work yourself.
- If a task is genuinely stuck, dispatch a fresh subagent with the specific
  blocker and what to do about it — don't let one bad run cascade.
