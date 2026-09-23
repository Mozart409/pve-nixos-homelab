# Hermes Agent Findings — Upstream State & Capability Gaps

Date: 2026-09-23
Scope: (1) how far behind our pinned `hermes-agent` input is and whether it can be
unpinned; (2) what the agent on `hosts/hermes` still cannot do and what upstream now
offers to close each gap.

Not covered here: why the host is commented out of the colmena hive (see §6).

## 1. Where We Are Pinned

`flake.nix` pins the input to a rev, not a branch:

```nix
hermes-agent.url = "github:NousResearch/hermes-agent/98105f31f46d3de58a8f69a2a439cee3f7a5e389";
```

`flake.lock` dates that rev to **2026-07-31**. Upstream tags by date now
(`vYYYY.M.D`), with a parallel semver in the release title:

| Tag | Date | Title |
| --- | --- | --- |
| `v2026.9.21` | 2026-09-21 | 0.21.4 — ~1,800 PRs; gateway singleton lock, desktop backend, structured JSON output, skill auto-loading, MCP discovery config |
| `v2026.9.14` | 2026-09-14 | 0.21.3 — remote gateway session expiry, state.db writer handles |
| `v2026.9.11` | 2026-09-11 | 0.21.2 — state.db reliability campaign (44 issues), multi-profile isolation |
| `v2026.9.7`  | 2026-09-07 | 0.21.1 — modularization, startup perf, **cron scheduling + delivery fixes** |
| `v2026.8.31` | 2026-08-31 | 0.21.0 "Pantheon" — bot mode, `hermes peer`, stateful cron, live subagent steering, MCP command center, in-app browser control |
| `v2026.8.27` | 2026-08-27 | 0.20.6 — remote MCP catalog (50+ vendors), TTL result caching, keychain encryption |

We are roughly **eight weeks and five releases behind**, currently sitting a few
commits ahead of 0.20.1.

## 2. The Reason For The Pin Is Fixed Upstream

The pin comment blames a startup crash:

```
File ".../hermes_cli/plugins.py", line 62, in <module>
    from registration_lifecycle import replacement_coordinator
ModuleNotFoundError: No module named 'registration_lifecycle'
```

That was a **packaging** bug, not a code bug: the module was never listed in
`pyproject.toml`'s `py-modules`, so the sealed uv2nix venv did not contain it.
The fix is commit `89d3e43` on main — a one-line addition of
`"registration_lifecycle"` to `py-modules`.

Upstream then added a regression guard: PR #85160 (`test(nix): verify plugin imports
in sealed venv`, merged 2026-09-20) extends `nix/checks.nix` with a check that runs
the sealed venv's interpreter in isolated mode (`python -I`) and imports both
`registration_lifecycle` and its consumer `hermes_cli.plugins`.

**Conclusion: the pin can be lifted.** The exact failure mode we hit is now covered
by an upstream build-time check.

## 3. Unpinning Is Not Free — Three Things To Check First

### 3.1 The plugin import decomposition breaks out-of-tree plugins (highest risk)

`COMPAT_MANIFEST.md` documents PR #102117, a September 2026 code decomposition with
**2,088 name mappings** (1,148 lazily moved names, 592 third-party/stdlib imports,
290 restored definitions, 34 unrestorable). A temporary compat shim emitted
`HermesPluginCompatWarning`; per the manifest that shim was **removed on 2026-09-14**,
after which plugins importing the old paths are **disabled outright**.

We run exactly one out-of-tree plugin — `plugins.enabled = ["moshi-hooks"]`, whose
code is written into the state dir by `moshi-hook install` (`hosts/hermes/moshi-hook.nix`),
not by Nix. It is therefore pinned to whatever import paths moshi-hook 0.3.16 was
built against.

Before/after the bump, on the hermes host:

```bash
sudo -u hermes hermes plugins compat /var/lib/hermes/.hermes/plugins/moshi-hooks
# prints every file:line, old path -> new path; exits 1 while anything remains
```

If it exits non-zero, the bump needs a newer `moshi-hook` release
(`modules/moshi-hook.nix`, version + sha256 from the rjyo/homebrew-moshi formula)
before `plugins.enabled` can stay on. Note the knock-on: a moshi-hook version bump
re-runs `moshi-hook install`, which re-triggers the config.yaml mixed-indent
corruption that `hermes-config-check` exists to repair (AGENTS.md §6). That machinery
is unchanged upstream and still needed.

### 3.2 The NixOS module option surface grew

Everything `hosts/hermes/configuration.nix` uses still exists on main:
`stateDir` (still `/var/lib/hermes`), `workingDirectory` (still `${stateDir}/workspace`),
`addToSystemPackages`, `settings`, `environment`, `environmentFiles`, `documents`,
`mcpServers`, `extraPackages`, `extraPythonPackages`, `user`/`group`/`createUser`.
`installPackage` was removed in favour of `programs.hermes-agent.enable` — we never
used it.

New options worth knowing about:

- `hermesHomeFiles` — files installed into `HERMES_HOME`, documented as the home for
  **SOUL.md and memories**. We install SOUL.md/USER.md via `documents`, i.e. into
  `workingDirectory`. **Verify which path the new version actually reads the system
  prompt from before deploying** — if it moved, our prompt silently stops loading, and
  the `ReadOnlyPaths` bind on `${hermesHome}/workspace/SOUL.md` has to move with it.
- `backend.{mode,host,port,waitFor,interfaceName,waitTimeout,sessionTokenFile,extraArgs}` —
  `mode` is `none`/`serve`/`dashboard`, default port 9119. A first-class web dashboard,
  separate from the api_server we proxy on 8642.
- `container.{enable,backend,image,extraVolumes,extraOptions,hostUsers}` — the podman
  jail we tore out is now a supported module mode (docker or podman). Relevant only if
  we ever want that boundary back; the systemd sandbox remains our current answer.
- `extraPlugins` (directory plugins with a `plugin.yaml`), `extraDependencyGroups`,
  `authFile` / `authFileForceOverwrite`.
- `mcpServers.<name>` submodule now takes `auth`, `enabled`, `timeout`,
  `connect_timeout`, `tools` (include/exclude) and `sampling` limits — see §5.5.

`ExecStart` is still `hermes gateway run --replace`.

### 3.3 The api_server contract is unchanged

Good news for the Caddy/Open WebUI path: `API_SERVER_ENABLED`, `API_SERVER_PORT`
(default still **8642**), `API_SERVER_HOST` and `API_SERVER_KEY` are all still the
documented env interface, env still wins over `config.yaml`, and the platform key for
`platform_toolsets` is still `api_server`. `API_SERVER_KEY` is documented as required
for every deployment — we already supply it from `hermes-api-server-key.age`.

One thing to re-check after the bump: v2026.9.21 adds a **host-wide gateway singleton
lock**. The `launch-hermes` wrapper starts an interactive TUI as the same `hermes`
user while `hermes-agent.service` is running; confirm the two still coexist, or that
`--replace` does not evict the service.

## 4. Capability Gaps And How Upstream Closes Them

### 4.1 `web_extract` has no backend — a real, known dead end

Our config sets `web.search_backend = "searxng"` and notes "SearXNG does not back
`web_extract`, so that tool stays unconfigured". Upstream now has a **capability-based
provider split**, and our exact symptom is filed as issue #32698
("web_extract gives dead-end error with only SearXNG configured").

The fix is a second key:

```yaml
web:
  search_backend: "searxng"     # free, self-hosted (SEARXNG_URL) — search only
  extract_backend: "firecrawl"  # or tavily / exa / parallel / keenable / perplexity
```

Provider capabilities:

| Provider | Search | Extract | Key |
| --- | --- | --- | --- |
| SearXNG | yes | **no** | none (`SEARXNG_URL`) |
| Brave | yes | no | `BRAVE_SEARCH_API_KEY` required |
| DDGS | yes | no | none |
| Firecrawl | yes | yes | optional — keyless free tier ~500 credits/mo |
| Tavily | yes | yes | optional (keyless tier) |
| Exa | yes | yes | optional — 1000 searches/mo free |
| Parallel / Keenable | yes | yes | optional (keyless ring) |
| Perplexity / xAI / OpenAI-native | yes | varies | required, paid |

Recommendation: keep SearXNG for search (it is ours, free, no quota) and add
`extract_backend = "firecrawl"` on the keyless tier; upgrade to an `EXA_API_KEY` or
`FIRECRAWL_API_KEY` in agenix if the free tier throttles.

Other new `web.*` knobs worth setting explicitly: `extract_char_limit` (default 15000,
range 2000–500000), `extract_timeout` (120s), `cache_enabled` / `cache_ttl_minutes`,
`cache_exempt_hosts`, `keyless_fallback` (default true) and `keyless_rescue`.

Security note: an extract backend pulls arbitrary page content into an agent that has
a shell with `approvals.mode = "off"`. Pair this change with §4.3.

### 4.2 `browser` is enabled but has no engine

`browser` is listed in `toolsets` and in both the `api_server` and `cli`
`platform_toolsets`, but the config comment concedes it "needs a Chromium/CDP backend
to actually drive a page". Upstream browser mode is now a driver over a selectable
source, with this precedence: cloud provider (browserbase / browser-use / camofox /
nous) > Camofox > `browser.cdp_url` or `/browser connect` > `browser.use_real_profile`
> `browser.engine`.

Keys: `browser.backend` (`browser-use` | `off` | unset), `browser.engine`
(`auto` | `chrome` | `lightpanda`), `browser.cloud_provider`, `browser.cdp_url`,
`browser.headed`, `browser.allow_private_urls` (default false),
`browser.auto_local_for_private_urls` (default true), `browser.snapshot_threshold`
(15000 chars), `browser.inactivity_timeout` (120s), `browser.dialog_policy`
(`must_respond` default), `browser.restrict_evaluate`, `browser.record_sessions`.

Headless Linux is explicitly supported — `AGENT_BROWSER_ARGS` auto-injects
`--no-sandbox,--disable-dev-shm-usage` on root/AppArmor-restricted hosts, and pages
are handed to the model as accessibility trees with `@e1`-style ref IDs, not
screenshots.

**NixOS caveat.** The default path resolves `agent-browser` via `npx` on first use and
lets it download Chrome for Testing — a dynamically linked binary that will not run on
NixOS without an FHS wrapper. Three workable routes, in order of preference:

1. `browser.engine = "lightpanda"` — documented as needing no Chromium and no Node.
2. Add `pkgs.chromium` to `extraPackages` and point `CHROME_PATH` / `BH_CHROME_PATH`
   at it (documented as first in the binary resolution order), so nothing is downloaded.
3. Run chromium `--remote-debugging-port` as its own systemd unit and set
   `browser.cdp_url` at it — most control, most moving parts.

Two host-specific follow-ons: `ProtectSystem=strict` means the browser's profile dir
must land under `stateDir`, and driving anything on the LAN needs both
`browser.allow_private_urls = true` and a matching `IPAddressAllow` entry in the unit.

Until one of these is wired up, consider dropping `browser` from `toolsets` and the
platform lists — a dead toolset still costs tool-schema tokens on every LLM call.

### 4.3 Approvals are fully off, and upstream now has a middle setting

`approvals.mode = "off"` was chosen because "manual" blocked on an interactive
`approval.request` the Open WebUI chat-completions gateway can never answer. That
trade-off is obsolete:

- **`approvals.mode` is now `smart` by default** (was `manual`). An auxiliary LLM
  adjudicates each flagged command: auto-approves low risk, auto-denies dangerous,
  escalates only the uncertain middle. Configured under `auxiliary.approval`
  (`provider`, `model`, `base_url`, `api_key`).
- **`approvals.unattended_mode`** (`deny` | `approve`) decides what an escalation does
  on a surface with no human — api_server, webhook, peer. There are sibling keys
  `cron_mode` and `single_query_mode`.

So the headless hang we designed around is now a first-class configuration, not a
reason to disable the layer. Suggested setting:

```nix
approvals = {
  mode = "smart";
  unattended_mode = "approve";   # "deny" if we want the tighter posture
};
auxiliary.approval = { provider = "deepseek"; model = "deepseek-v4-flash"; };
```

That buys back a policy layer we currently have none of, at flash-tier cost per flagged
command, without reintroducing a blocking prompt.

Related hardening that landed in 0.21.0 and partly overlaps our own:

- The non-bypassable hardline blocklist is unchanged (`rm -rf /`, fork bombs, `mkfs.*`
  on mounted devices, `dd` to `/dev/sd*`) — still the floor under `mode: off`.
- `write_file` / `patch` are now hard-blocked on `~/.ssh/`, `~/.aws/`, `.env` and vault
  dirs (with `~/.ssh/config` routed through approvals instead).
- Protected instruction files now require write approval — a model-level echo of our
  `ReadOnlyPaths` bind on `config.yaml` / `SOUL.md` / `USER.md`. **Keep ours**: a bind
  mount is enforced by the kernel, theirs by the agent.
- MCP subprocesses now get a filtered environment (only `PATH`, `HOME`, `USER`, `LANG`,
  `LC_ALL`, `TERM`, `SHELL`, `TMPDIR`, `XDG_*`); secrets must be passed explicitly via
  the server's `env`. Our two MCP servers are HTTP, so this does not bite us.

### 4.4 Cron result delivery is hand-rolled; upstream now does it natively

SOUL.md plus the `cron-result-delivery` skill implement delivery by hand: append to
`Inbox.md`, commit and push the vault, then fire `hamcp_call_service` at
`notify.mobile_app_iphone_von_amadeus`. Upstream cron now carries a per-job `deliver`
target and delivers the agent's final response itself — "the agent does not send
messages itself, so there is nothing to call in the cron prompt". Supported targets
include **`homeassistant`** and **`webhook`** alongside the chat platforms, plus
`platform:chat_id` addressing and `origin`/`local`.

It also tracks delivery separately from execution: a run whose output never landed
records `last_status: delivery_failed` with `last_delivery_error`, instead of a green
`ok`. We have no equivalent visibility today — a silently dropped push looks like
success.

0.21.0 additionally gives cron jobs **persistent memory between runs**, and lets a job
skip the LLM call entirely when nothing changed — directly relevant to cost on any
polling job.

Recommendation after the bump: set `deliver` to `homeassistant` (or a webhook), keep
only the `Inbox.md` archival half of the skill, and drop the notify plumbing from
SOUL.md.

### 4.5 Capabilities we simply do not have yet

- **Bot mode / `hermes peer`** — named agents with avatars in group chats, and durable
  agent-to-agent DMs across profiles. A second agent profile (e.g. an ops-only one with
  no vault write access) becomes practical.
- **Live subagent steering** — our `delegation` toolset is enabled but blind; upstream
  now offers mid-flight monitoring and steering, per-delegation cost tracking, JSON
  schema validation on results, and early halt with partial results preserved.
- **MCP command center** — health checks, usage and cost analytics per MCP server.
  Directly useful for axon-gateway, whose backend evictions we currently only notice
  when a tool call fails.
- **Per-MCP-server narrowing** — `tools` include/exclude, `trust` levels, `timeout` /
  `connect_timeout`, and `sampling` caps. Today `axon-gateway` and `agentmail` both
  expose their entire tool surface unconditionally.
- **`backend.mode = "dashboard"`** (port 9119) — a real web dashboard with remote
  sessions, as an alternative or companion to Open WebUI over the 8642 api_server.
- **Terminal backends** — now local, docker, ssh, singularity, modal, daytona and
  vercel sandbox. `ssh` is the interesting one: the agent could act on another homelab
  host without us relaxing this unit's `IPAddressAllow`.
- **v2026.9.21 odds and ends** — skill auto-loading, structured JSON output, MCP
  discovery config, and a dozen community plugins including tailscale, ssh and rss.

## 5. Order Of Work

1. **Unblock the host.** `hermes` is commented out of the colmena hive (`flake.nix`,
   "Inactive 2026-09-09: No route to host"). `nixosConfigurations.hermes` still
   evaluates, so changes can be type-checked, but nothing ships until it is reachable.
2. **Bump the input** to `v2026.9.21` on a branch and type-check the host only:
   `nix eval '.#nixosConfigurations.hermes.config.system.build.toplevel.drvPath'`.
   Do not run the full `nix flake check` (OOMs on ~16 hosts); leave the actual
   `colmena build`/`apply` to a session that can afford the compile.
3. **Check moshi-hooks** against the decomposition (§3.1) and confirm where SOUL.md is
   read from (§3.2) *before* deploying. Bump `secretNonce` — none of this restarts the
   unit otherwise.
4. **Then the settings work**, cheapest first: `web.extract_backend` (§4.1),
   `approvals.mode = "smart"` (§4.3), cron `deliver` (§4.4), browser engine (§4.2).

## 6. Sources

- Releases: <https://github.com/NousResearch/hermes-agent/releases>,
  <https://github.com/NousResearch/hermes-agent/releases/tag/v2026.8.31>
- Packaging fix: commit `89d3e43`; regression test PR
  <https://github.com/NousResearch/hermes-agent/pull/85160>
- Plugin decomposition: `COMPAT_MANIFEST.md` (PR #102117)
- Module options: `nix/moduleCommon.nix`, `nix/nixosModules.nix`
- Docs: `website/docs/user-guide/features/{browser,web-search,api-server,cron}.md`,
  `website/docs/user-guide/security.md`
- Issues: #32698 (web_extract dead end with SearXNG only), #112819 (`browser_exec`
  lazy Chrome launch), #111973 (approving an unattended api_server session)
