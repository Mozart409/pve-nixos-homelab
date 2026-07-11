---
name: cron-result-delivery
description: Deliver the result of an unattended scheduled (cron) job to the user, who otherwise never sees it. Use this on EVERY cron/scheduled run, because a cron session has no chat to reply into — Open WebUI is pull-based and cannot receive a server-initiated message. Delivers via two channels: an append to the vault Inbox note and a Home Assistant push notification.
platforms: [linux]
required_environment_variables:
  - OBSIDIAN_VAULT_PATH
required_commands:
  - git
---

# Cron Result Delivery

Use this skill whenever you are running as an **unattended scheduled (cron)
job** — i.e. the gateway started this session from a saved schedule, not from a
person typing in a chat.

## Why this exists

The only interactive channel is Open WebUI, which is **pull-based**: it opens a
request, sends the prompt, and reads your reply. The server can never push a
**new** conversation into it. So when you finish a cron job, there is *no chat to
answer into* — your result would simply be logged on the host and never reach
the user. You must deliver it out-of-band, through the two channels below.

Deliver through **both** channels on every cron run. The Inbox note is the
durable record; the Home Assistant push is what actually reaches the user's
phone.

## Channel 1 — Vault Inbox note (always do this)

**Path layout (important):** `OBSIDIAN_VAULT_PATH`
(`/var/lib/hermes/workspace/vault`) is the **git repo root** — it holds
`flake.nix`, not notes. The actual Obsidian notes (including `Inbox.md`) live one
level down in the **`vault/` subdirectory**. So:
- Note file: `$OBSIDIAN_VAULT_PATH/vault/Inbox.md`
- Git repo (where you commit): `$OBSIDIAN_VAULT_PATH`

Steps:

1. `read_file` `$OBSIDIAN_VAULT_PATH/vault/Inbox.md`. If it does not exist,
   create it with a `# Inbox` heading.
2. Append a section, newest at the **top** under the heading:
   ```
   ## YYYY-MM-DD HH:MM — <one-line job summary>

   <the full result: what the job did, findings, any numbers, next actions>
   ```
   Use the `write_file`/`patch` file tools (they handle the path cleanly); do not
   rely on `echo >>` via terminal.
3. Commit at the repo root (a host service pushes it automatically within
   seconds — **never** `git push`/`pull` yourself):
   ```
   cd "$OBSIDIAN_VAULT_PATH" && git add -A && git commit -m "docs(vault): cron result — <short summary>"
   ```

## Channel 2 — Home Assistant push (do this when the tool is available)

Send a short push via the **`hamcp_call_service`** tool. This is the Home
Assistant `call_service` tool exposed through the `axon-gateway` MCP, which
namespaces each backend's tools with a `hamcp_` prefix. (Verified working
2026-07-11: this exact call delivered a push to the user's iPhone.)

**Send the notification** — call `hamcp_call_service` with:
- `domain` = `notify`
- `service` = `mobile_app_iphone_von_amadeus`  (the user's iPhone; the `notify.`
  prefix is dropped — `domain` supplies it)
- `service_data` = `{ "title": "<job name>", "message": "<one-line result — see Inbox for detail>" }`

Keep the push to one line. Put the full detail in the Inbox note, not the push.
A successful call returns `isError: false` with empty `changed_states` (normal
for `notify` — it is fire-and-forget, not a state change).

**Fallbacks (in order):**
- If `mobile_app_iphone_von_amadeus` ever fails (device renamed), call
  `hamcp_get_services`, find the current `notify.mobile_app_*` service, use it,
  and record the new name as a memory fact `ha_notify_service`.
- If neither works, use `hamcp_call_service` with
  `domain="persistent_notification"`, `service="create"`,
  `service_data={ "title": ..., "message": ... }` (shows in the HA companion
  app's notifications panel).
- If `hamcp_call_service` is **not available in this session at all** (MCP not
  exposed to cron), skip Channel 2 and add a line to the Inbox entry:
  `> ⚠️ HA push unavailable in this cron session (no hamcp_call_service tool).`
  so the user knows to wire a host-side notifier instead.

## Seed memory once (so cron runs recall this procedure)

Because a cron run must actively *choose* to load this skill, store a durable
memory fact the first time you use it, so it resurfaces on future scheduled
runs:

- Fact: *"When running as a scheduled/cron job, deliver results via the vault
  Inbox note AND a Home Assistant push — load the `cron-result-delivery`
  skill."*

## Pitfalls

- **Never `git push`/`pull` in the vault** — the host sync service does that.
- **Never** put the full result in the HA push; it is a one-line nudge. The
  Inbox note holds the detail.
- The tool is `hamcp_call_service` (the `hamcp_` prefix is how axon-gateway
  namespaces the Home Assistant backend). A bare `call_service` will not resolve.
- The push service name drops the `notify.` prefix: `domain` is `notify`,
  `service` is `mobile_app_iphone_von_amadeus`.
- Only fall back to `hamcp_get_services` discovery if the known service name
  fails; do not re-discover on every run.
