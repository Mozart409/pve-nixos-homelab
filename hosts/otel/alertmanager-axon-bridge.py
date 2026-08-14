#!/usr/bin/env python3
"""Translate Alertmanager webhooks into a Home Assistant push via the axon gateway.

Alertmanager can only POST its own fixed JSON schema; the axon gateway only
speaks MCP JSON-RPC (`tools/call`). Neither end is configurable enough to meet
the other, so this sits between them.

Why the gateway rather than posting to Home Assistant directly, which would need
no bridge at all: Home Assistant has no *.homelab.local record. Its only names
are a MagicDNS ts.net name -- which does not resolve between homelab VMs, see
AGENTS.md -- and a bare .local name, which is mDNS-reserved and which unbound
therefore never gets asked about. axon.homelab.local resolves, carries a step-ca
cert this host already trusts, and is the exact path
modules/claude-settings-verify.nix already uses in production.

Delivery is synchronous and the HTTP status back to Alertmanager reflects it: a
5xx makes Alertmanager retry and increments alertmanager_notifications_failed_total,
which is what the AlertmanagerNotificationsFailing rule watches. Swallowing
errors and always returning 200 would make a dead notification path invisible --
the precise failure mode this whole change exists to eliminate.
"""

import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

AXON_URL = os.environ.get("BRIDGE_AXON_URL", "https://axon.homelab.local/mcp")
NOTIFY_ENTITY = os.environ.get("BRIDGE_NOTIFY_ENTITY", "notify.iphone_von_amadeus")
LISTEN_PORT = int(os.environ.get("BRIDGE_PORT", "9099"))

# Alertmanager groups by alertname, so a rebooting host can produce a long list.
# Push notifications truncate anyway; the Alertmanager UI has the full set.
MAX_LISTED = 10

# Shorter than Alertmanager's own webhook timeout, so we answer it rather than
# letting it time out on us and lose the status distinction.
AXON_TIMEOUT_SECS = 8


def log(msg, err=False):
    print(f"alertmanager-axon-bridge: {msg}", file=sys.stderr if err else sys.stdout, flush=True)


def format_message(payload):
    """Render an Alertmanager payload as a short push notification body."""
    status = payload.get("status", "unknown").upper()
    alerts = payload.get("alerts", [])
    name = payload.get("groupLabels", {}).get("alertname") or "alerts"

    marker = "[RESOLVED]" if status == "RESOLVED" else "[FIRING]"
    lines = [f"{marker} {name} ({len(alerts)})"]

    for alert in alerts[:MAX_LISTED]:
        labels = alert.get("labels", {})
        summary = alert.get("annotations", {}).get("summary")
        if summary:
            lines.append(f"- {summary}")
        else:
            # No annotation to lean on: fall back to whatever identifies it.
            instance = labels.get("instance", "?")
            job = labels.get("job")
            lines.append(f"- {instance} ({job})" if job else f"- {instance}")

    if len(alerts) > MAX_LISTED:
        lines.append(f"...and {len(alerts) - MAX_LISTED} more")

    return "\n".join(lines)


def send_notification(message, token):
    """POST the MCP tools/call to the axon gateway. Raises on any failure."""
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "hamcp_call_service",
                "arguments": {
                    # notify *entities* use notify.send_message + entity_id, not
                    # the legacy notify.<service> form.
                    "domain": "notify",
                    "service": "send_message",
                    "entity_id": NOTIFY_ENTITY,
                    "service_data": {"message": message},
                },
            },
        }
    ).encode()

    request = urllib.request.Request(
        AXON_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    with urllib.request.urlopen(request, timeout=AXON_TIMEOUT_SECS) as response:
        response.read()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            log(f"malformed payload: {exc}", err=True)
            # Retrying will not fix malformed JSON, so do not ask it to.
            self.respond(400, b"bad request")
            return

        token = os.environ.get("AXON_GATEWAY_TOKEN")
        if not token:
            log("AXON_GATEWAY_TOKEN unset -- cannot notify", err=True)
            self.respond(500, b"no token")
            return

        try:
            send_notification(format_message(payload), token)
        except Exception as exc:
            log(f"notify failed: {exc}", err=True)
            self.respond(502, b"notify failed")
            return

        log(f"notified: {payload.get('status')} {payload.get('groupLabels', {})}")
        self.respond(200, b"ok")

    def respond(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Silence the default per-request stderr line; log() already covers the
        # outcomes worth having in the journal.
        pass


def main():
    server = HTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    log(f"listening on 127.0.0.1:{LISTEN_PORT}, forwarding to {AXON_URL}")
    server.serve_forever()


if __name__ == "__main__":
    main()
