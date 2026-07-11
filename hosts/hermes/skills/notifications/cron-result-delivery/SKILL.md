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

Append a timestamped entry to `Inbox.md` at the root of `OBSIDIAN_VAULT_PATH`
(fall back to `/var/lib/hermes/workspace/vault` if unset).

1. `read_file` `<vault_path>/Inbox.md`. If it does not exist, create it with a
   `# Inbox` heading.
2. Append a section, newest at the **top** under the heading:
   ```
   ## YYYY-MM-DD HH:MM — <one-line job summary>

   <the full result: what the job did, findings, any numbers, next actions>
   ```
3. Commit in the vault (a host service pushes it automatically within seconds —
   **never** `git push`/`pull` yourself):
   ```
   cd "$OBSIDIAN_VAULT_PATH" && git add -A && git commit -m "docs(vault): cron result — <short summary>"
   ```

## Channel 2 — Home Assistant push (do this when the tool is available)

Send a short push via the Home Assistant **`call_service`** tool (provided by the
`axon-gateway` / `hamcp` MCP backend).

**First run — discover and remember the notify target.** Notify services are
named per-device (`notify.mobile_app_<device>`) and you cannot guess the device.

1. Recall the stored target: check memory for a fact named
   `ha_notify_service`. If present, use its value and skip discovery.
2. If absent, call `call_service` with `domain="notify"`, `service="get_service"`
   is NOT valid — instead call the **`get_services`** tool and look under the
   `notify` domain for a `mobile_app_*` service. Pick the user's phone.
3. **Store it in memory** so future cron runs skip discovery: save a fact
   `ha_notify_service` = the full service name (e.g. `notify.mobile_app_pixel_8`).

**Send the notification** via `call_service`:
- `domain` = `notify`
- `service` = the discovered service name **without** the `notify.` prefix
  (e.g. `mobile_app_pixel_8`)
- `service_data` = `{ "title": "<job name>", "message": "<one-line result — see Inbox for detail>" }`

Keep the push short (one line). Put the full detail in the Inbox note, not the
push.

**Fallbacks (in order):**
- If no `mobile_app_*` service exists, use `domain="persistent_notification"`,
  `service="create"`, `service_data={ "title": ..., "message": ... }` (shows in
  the HA companion app's notifications panel).
- If the `call_service` tool is **not available in this session at all** (MCP not
  exposed to cron), skip Channel 2 and add a line to the Inbox entry:
  `> ⚠️ HA push unavailable in this cron session (no call_service tool).`
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
- **Do not guess** the `mobile_app_*` device name — discover it via
  `get_services` and remember it.
- The push service name in `call_service` drops the `notify.` prefix (`domain` is
  `notify`, `service` is `mobile_app_<device>`).
