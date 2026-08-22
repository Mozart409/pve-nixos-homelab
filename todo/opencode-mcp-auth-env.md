# opencode MCP auth fails outside interactive shells

**Resolved 2026-08-22** by `f616132 fix(herdr): forward MCP tokens into the
opencode shared-server unit`. The root cause below turned out to be narrower
than first suspected — see "What verification found" before reusing this
diagnosis elsewhere.

## Problem

`opencode` on hosts importing `modules/coding-harness.nix` reported
`server "axon-gateway" requires authentication. Run: opencode mcp auth axon-gateway`
whenever the shared `opencode serve` instance (see `modules/herdr.nix`) was
launched, regardless of whether the launching shell was interactive.

## What verification found

The "interactive vs non-interactive shell" framing below was wrong. Live
inspection on `development` showed:

- `environment.interactiveShellInit` (coding-harness.nix) does populate the
  token in every interactive shell, including herdr panes — confirmed, tokens
  present.
- The actual break: `modules/herdr.nix`'s `opencode()` wrapper starts the
  shared server via `systemd-run --user --unit=opencode-server`, and that
  transient unit's parent is the **systemd --user manager** (PID 1's child),
  not the calling shell — `ps -o ppid=` on the running server showed this
  directly. `systemd-run` does not forward the caller's environment by
  default, so `/proc/<server-pid>/environ` had neither
  `AXON_GATEWAY_TOKEN` nor `VENTARA_GATEWAY_TOKEN`, no matter how the shell
  that ran `systemd-run` got its own copy.
- No unattended `claude` launch path was found on `development` outside
  herdr's interactive panes, so `claude` was likely never actually affected —
  the original problem statement's mention of it was unverified.

## Fix applied

`modules/herdr.nix`'s `opencode()` wrapper now passes
`--setenv=AXON_GATEWAY_TOKEN --setenv=VENTARA_GATEWAY_TOKEN` (bare `NAME`, no
`=VALUE`) to the `systemd-run --user` call that starts `opencode-server`.
Bare `--setenv=NAME` forwards the *caller's current value* into the transient
unit, and is a silent no-op when the caller doesn't have the var set (verified
empirically) — so this is safe on hosts without `VENTARA_GATEWAY_TOKEN` too.
`interactiveShellInit` (coding-harness.nix) already guarantees both tokens are
set in the calling shell by the time `opencode()` runs, so no new secret
plumbing was needed — just forwarding what was already there across the
`systemd-run` boundary.

A server already running from before the fix was deployed needs
`systemctl --user restart opencode-server` once to pick up the tokens.

## Not done (deliberately out of scope)

The original theory generalized this to "any non-interactive launcher"
(systemd units, `ssh host cmd`, etc.) and proposed a host-wide mechanism
(`~/.config/environment.d/*.conf` or similar) to cover all of them. No such
launcher was found to actually exist on `development` — `claude` and
`opencode` both run inside herdr's interactive panes today — so that broader
mechanism was skipped as speculative. Revisit only if a genuine
systemd-launched (non-`systemd-run`-from-a-shell) agent process shows up.
