# Hermes upgrades

### systemd logs

Jun 20 23:43:40 homelab-hermes systemd[1]: hermes-agent.service: Scheduled restart job, restart counter is at 3.
Jun 20 23:43:42 homelab-hermes systemd[1]: Starting Hermes Agent Gateway...
Jun 20 23:43:42 homelab-hermes systemd[1]: Started Hermes Agent Gateway.
Jun 20 23:43:43 homelab-hermes hermes[206606]: ⚠ Deprecated .env settings detected:
Jun 20 23:43:43 homelab-hermes hermes[206606]:   ⚠ MESSAGING_CWD=/var/lib/hermes/workspace found in .env — this is deprecated.
Jun 20 23:43:43 homelab-hermes hermes[206606]:   Move to config.yaml instead:  terminal:\n    cwd: /your/project/path
Jun 20 23:43:43 homelab-hermes hermes[206606]:   Then remove the old entries from /var/lib/hermes/.hermes/.env
Jun 20 23:43:47 homelab-hermes hermes[206606]: WARNING hermes_plugins.raft_platform.adapter: [raft] raft CLI not found in PATH — install from https://raft.build


cx6mnlbnliz6p1rkb9-hermes-agent-env/bin/hermes gateway

Jun 20 23:45:07 homelab-hermes hermes[206725]:     await self._handle_post_request(ctx)
Jun 20 23:45:07 homelab-hermes hermes[206725]:   File "/nix/store/0ld7l0qlhsj4slcx6mnlbnliz6p1rkb9-hermes-agent-env/lib/python3.12/site-packages/mcp/client/streamable_http.py", line 358, in _handle_post_request
Jun 20 23:45:07 homelab-hermes hermes[206725]:     response.raise_for_status()
Jun 20 23:45:07 homelab-hermes hermes[206725]:   File "/nix/store/0ld7l0qlhsj4slcx6mnlbnliz6p1rkb9-hermes-agent-env/lib/python3.12/site-packages/httpx/_models.py", line 829, in raise_for_status
Jun 20 23:45:07 homelab-hermes hermes[206725]:     raise HTTPStatusError(message, request=request, response=self)
Jun 20 23:45:07 homelab-hermes hermes[206725]: httpx.HTTPStatusError: Client error '422 Unprocessable Entity' for url 'https://axon.homelab.local/mcp'
Jun 20 23:45:07 homelab-hermes hermes[206725]: For more information check: https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/422
Jun 20 23:45:07 homelab-hermes hermes[206725]: WARNING tools.mcp_tool: MCP server 'axon-gateway' failed initial connection after 3 attempts, giving up: unhandled errors in a TaskGroup (1 sub-exception)
Jun 20 23:45:07 homelab-hermes hermes[206725]: WARNING tools.mcp_tool: Failed to connect to MCP server 'axon-gateway': WouldBlock
Jun 20 23:45:08 homelab-hermes hermes[206725]: WARNING gateway.run: No user allowlists configured. All unauthorized users will be denied. Set GATEWAY_ALLOW_ALL_USERS=true in ~/.hermes/.env to allow open access, or configure platform allowlists (e.g., TELEGRAM_ALLOWED_USERS=your_id).

~/code/pve-nixos-homelab  main ?1   ☸ k3s

