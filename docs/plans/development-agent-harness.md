# Plan: declaratively reproduce the `scratchpad` agent harness on `development`

Status: **reviewed, decisions locked** — not yet implemented.
Branch: `worktree-development-declarative`

## Decisions (2026-07-27)

| Question | Decision |
|---|---|
| moshi-hook unit model (P0-2) | **User units + linger** — `systemd.user.services.{moshi-hook,moshi-hook-setup}` + `users.users.amadeus.linger = true`, matching the verified scratchpad setup. |
| Claude Code auth (P1-6) | **Manual `claude login`** (option a) — document as a one-time post-deploy step. No new secret. |
| herdr scope (P1-7) | **`config.toml` + `herdr integration install opencode`** only. The three GitHub plugins stay runtime-installed. |
| Out-of-scope extras (§4) | **Neither** — the zsh/home-manager port and the scratchpad decommission both stay as separate follow-up work. |
| opencode config filename (P2-9) | **`opencode.jsonc`** — retarget the `coding-harness.nix` merge; remove any stale `opencode.json`. |
| VM resize (P2-13) | **disk 32 → 256 GB, RAM 1024 → 4096 MiB (floating 2048), cores stay 2.** |
| Container tooling | **podman only, homelab-wide** — `docker-compose` → `podman-compose`, `dockerCompat = false` in `modules/podman.nix`, `common.nix` aliases repointed at podman. |
| herdr agent integrations | **opencode *and* claude** — the reference host only had opencode installed, but there is no technical reason to omit claude. |
| Provisioning method | **Reinstall via `nixos-anywhere`** — the VM holds nothing worth keeping. Disko repartitions the full disk, so no manual `growpart` needed. |
| opencode API key (P1-5) | **One key per consumer.** New `development-opencode-zen-key.age` encrypted to `development` only; `hermes-opencode-zen-key.age` untouched. Requires minting a new key in the opencode console. |
| Secret work timing | Deferred to **after** the reinstall — the new host key makes `just reencrypt` genuinely required. See §5 Phase C. |

## 0. What I found

### The reference box (`scratchpad`, 192.168.2.185)

Not NixOS — **Fedora 44 Cloud**, provisioned by `iac/main.tf:1063`
(`scratchpad_vm`, tags `terraform/fedora/scratchpad`), DNS at
`hosts/dns/configuration.nix:122,163`. No `hosts/scratchpad/`, no flake entry,
no colmena node. Everything on it was installed by hand.

| Component | Version | Install method | Path |
|---|---|---|---|
| moshi-hook | **0.2.59** | upstream tarball | `~/.local/bin/moshi-hook` |
| herdr | **0.7.5** | upstream installer | `~/.local/bin/herdr` |
| Claude Code | **2.1.220** | native installer | `~/.local/bin/claude` |
| opencode | **1.18.5** | native installer (179 MB) | `~/.opencode/bin/opencode` |
| bun | — | bun installer | `~/.bun/bin` |
| mosh, tmux, node, npm | — | dnf | `/usr/bin` |
| nix + standalone home-manager | 2.35.1 | Determinate + HM flake | `/nix`, `~/.config/home-manager` |

### The target (`development`, 192.168.2.184) is already ~90% built

`hosts/development/configuration.nix` already imports `moshi-hook-user.nix` and
`coding-harness.nix`, installs `claude-code` + `opencode` + `herdr`, and declares
both `age.secrets.moshi-device-id` and `age.secrets.axon-gateway-env`. It landed
in `3c4a62a` / `ab3e116`. The AGENTS.md §5 new-host checklist is **fully
satisfied** (DNS A + PTR, otel scrape job, `iac/main.tf` VM + output, flake
`hostAddrs` / `nixosConfigurations` / `colmenaHive`), and `hostDevelopment` is
already a recipient of both secrets it consumes.

**So this is gap-closing, not greenfield.** Below is the delta between what
provably works on scratchpad and what the repo currently declares.

---

## 1. P0 — blockers

### P0-1 · `nixosConfigurations.development` cannot evaluate

`flake.nix:210-218` builds `development` with an explicit `nixpkgs.lib.nixosSystem`
(needed for `specialArgs = {inherit herdr;}`) but **omits
`nixpkgs.config.allowUnfree = true`**, which `mkHost` sets at line 176 and which
the sibling explicit entry `jellyfin` sets deliberately at line 231. `claude-code`
is unfree, so:

```
nix eval .#nixosConfigurations.development.config.system.build.toplevel.drvPath
→ error: Package 'claude-code' has an unfree license — refusing to evaluate
```

`colmena apply` still works (`colmenaHive.meta.nixpkgs` sets `allowUnfree`), but
`nix flake check`, `nix build .#nixosConfigurations.development`, and
and `nix build .#nixosConfigurations.development` all fail.

**Fix:** add `nixpkgs.config.allowUnfree = true;` to the inline module, and add
`homeManagerNixvim` to the module list — same divergence jellyfin's comment at
`flake.nix:222-224` calls out (without it, the colmena build and the
nixosConfigurations build of `development` produce different systems).

### P0-2 · The moshi-hook daemon and its hooks will not agree on a socket path

This is the one that silently produces a *working-looking, non-functional* setup.

On scratchpad, moshi-hook runs as a **systemd `--user` unit** with
`loginctl Linger=yes`, so `XDG_RUNTIME_DIR=/run/user/1000` is set and
`moshi-hook status` reports:

```
socket: /run/user/1000/moshi-hook.sock
```

`modules/moshi-hook-user.nix:50-63` instead declares a **system** unit with
`User = "amadeus"`. System units do **not** get `XDG_RUNTIME_DIR`, so the daemon
falls back to a different socket path — while the Claude Code hook
(`moshi-hook claude-hook`, spawned from an interactive login shell) and the
opencode plugin (which does its own `resolveSocketPath`, honouring
`MOSHI_SOCKET_PATH`) resolve it from *their* environment. Daemon and hooks land
on different paths and no notification ever fires.

Worse, `moshiPairInstall` (`modules/moshi-hook-user.nix:18-33`) soft-fails with
`exit 0` on both an unreadable secret and a failed pair, so a completely unpaired
daemon reports `active (running)` and a green activation. Repo memory already
flags hermes's copy of this as *"agent-hook wiring unverified"* — same root cause.

**Fix (recommended, mirrors the verified-working box exactly):** convert to
`systemd.user.services.moshi-hook` + `systemd.user.services.moshi-hook-setup`,
and set `users.users.amadeus.linger = true;` so the daemon runs without an
active login session.

*Alternative:* keep the system units and pin
`Environment = "XDG_RUNTIME_DIR=/run/user/1000"` plus an explicit
`MOSHI_SOCKET_PATH` exported to interactive shells. Less faithful, more moving
parts — not recommended.

Either way this must be **verified after deploy** with
`moshi-hook status` (expect `status: paired`) and a real notification round-trip
to the iOS app — a green systemd unit proves nothing here.

### P0-3 · moshi-hook is pinned one patch behind, and the module's comment is wrong

`modules/moshi-hook.nix:16` pins `0.2.58`; scratchpad runs `0.2.59`.

More importantly, `modules/moshi-hook-user.nix:13-17` claims opencode's hook file
is *project-local* (`.opencode/plugins/moshi-hooks.ts`) and that
`moshi-hook install` "must be rerun by hand from inside each new opencode project
directory". **That is not true for this version.** On scratchpad:

```
hooks:
  claude   current  /home/amadeus/.claude/settings.json
  opencode current  /home/amadeus/.config/opencode/plugins/moshi-hooks.ts
```

The opencode plugin is **global, under `$HOME`**, and `moshi-hook install` covers
it. So the single `moshi-hook-setup` oneshot is sufficient — no per-project
manual step, no justfile escape hatch needed.

**Fix:** bump to `0.2.59` (+ new sha256), delete the stale comment.

---

## 2. P1 — functional parity

### P1-4 · opencode's global plugins need a JS runtime and npm deps

Both `~/.config/opencode/plugins/moshi-hooks.ts` and
`herdr-agent-state.js` import from `@opencode-ai/plugin` and `bun:sqlite`.
Scratchpad accordingly carries `~/.config/opencode/package.json`
(`@opencode-ai/plugin@1.18.4`), `package-lock.json`, a 584-entry `node_modules/`,
and a bun install. `development` has none of `bun`, `nodejs`, or `npm`.

**Fix:** add `bun` (and `nodejs`) to `hosts/development/configuration.nix`
`systemPackages`. opencode bootstraps its own plugin `node_modules` on first run,
so no activation step should be needed — **verify this on the deployed host**
rather than assuming it, and add a oneshot only if it turns out opencode expects
the deps pre-seeded.

### P1-5 · opencode auth (opencode-zen key) is not declarative

Scratchpad has `~/.local/share/opencode/auth.json`:
`{"opencode": {"type": "api", "key": "…"}}` — an opencode-zen key, exactly the
shape hermes materialises with its bespoke `writeShellScriptBin "opencode"`
wrapper at `hosts/hermes/configuration.nix:827-838` from
`age.secrets.hermes-opencode-zen-key`.

`modules/coding-harness.nix` configures **MCP only** — no provider, no auth.

**Fix — a separate key per consumer, not a shared one.** `development` gets its
own opencode-zen API key rather than becoming a recipient of hermes's. That keeps
the blast radius of a leak to one host, makes revocation per-host, and keeps
per-host usage attributable in the opencode console.

**You are minting and adding the key** — steps 1-3 are yours, so here is the
exact contract the module code will assume:

1. **Mint a new opencode-zen key** in the console for this host. *(Must be an
   account key with billing, or only the free models appear — see the note at
   `hosts/hermes/configuration.nix:825`.)*
2. Create `secrets/development-opencode-zen-key.age` in hermes's env-file format
   — a single line, `OPENCODE_ZEN_API_KEY=<key>`. (Env-file, **not** a bare
   token: `moshi-device-id.age` is the bare-token one, this one is sourced.)
3. `secrets/secrets.nix`, keep-sorted between `dashboard-env` and
   `fleet-enroll-secret`:
   ```nix
   "development-opencode-zen-key.age".publicKeys = [amadeus amadeusAge hostDevelopment];
   ```
   **`hermes-opencode-zen-key.age:48` stays untouched** — no new recipient, no
   re-encrypt, hermes unaffected.

Mine from here:

4. `hosts/development/configuration.nix`: declare it under the *generic*
   attribute name, mirroring the existing `axon-gateway-env` convention:
   ```nix
   age.secrets.opencode-zen-key = {
     file = ../../secrets/development-opencode-zen-key.age;
     owner = "amadeus";
     mode = "0400";
   };
   ```
5. `modules/coding-harness.nix`: add an auth.json writer that reads
   `config.age.secrets.opencode-zen-key.path` and materialises
   `~/.local/share/opencode/auth.json`. Port the umask-077 write from hermes's
   wrapper (`hosts/hermes/configuration.nix:827-838`), but **deep-merge rather
   than overwrite** — opencode writes other providers into that file.

The host supplies the *file*, the module names the *attribute* — so each host
points at its own `.age` and no key is ever shared. This is the same split the
module already documents for `axon-gateway-env` (`modules/coding-harness.nix:110-113`).

> ⚠️ **`zeroclaw` also imports this module** (`hosts/zeroclaw/configuration.nix:15`)
> and declares no opencode secret. Gate the writer on
> `config.age.secrets ? opencode-zen-key` so zeroclaw keeps evaluating; give it
> its own key later if it ever needs one.

> **`axon-gateway-env.age` stays shared — by design.** axon-gateway is an *MCP
> aggregator*: one endpoint fronting all the backends, so each host configures a
> single MCP server instead of six. A shared bearer token is the point, not an
> oversight. The one-key-per-consumer rule applies to upstream *provider* API
> keys (opencode-zen), not to this.

### P1-6 · Claude Code auth is not declarative — needs a decision

Scratchpad authenticates via `~/.claude/.credentials.json`, produced by an
interactive OAuth `claude login`. There is **no Anthropic/Claude secret anywhere
in the repo**. Options:

- **(a)** Accept a one-time manual `claude login` on first boot; document it in
  AGENTS.md §5 and in the host file. Survives redeploys (it is mutable `$HOME`
  state), lost on reprovision.
- **(b)** Add a `claude-credentials.age` secret and materialise it. Captures the
  OAuth token, which rotates — likely to go stale and fail confusingly.
- **(c)** Add an `ANTHROPIC_API_KEY` agenix secret sourced from
  `environment.interactiveShellInit` alongside `AXON_GATEWAY_TOKEN`. Fully
  declarative, but bills API usage rather than the subscription.

**Recommendation: (a).** ← *needs your call*

### P1-7 · herdr is installed but entirely unconfigured

`hosts/development/configuration.nix:98` adds the binary and nothing else. herdr
appears in exactly three lines in the whole repo. Scratchpad has:

- `~/.config/herdr/config.toml` (173 B) — `onboarding = false`,
  `ui.show_agent_labels_on_pane_borders = true`, `agent_panel_sort = "priority"`,
  `ui.toast.delivery = "herdr"`, `theme.name = "dracula"`, `auto_switch = false`
- `herdr integration install opencode` → `~/.config/opencode/plugins/herdr-agent-state.js` (v9, `current`).
  The `claude` integration was **not** installed on scratchpad — **we install it
  anyway**, see below.
- Three runtime-downloaded GitHub plugins in `~/.config/herdr/plugins/github/`:
  `herdr-file-viewer` 1.14.0, `nathanflurry.jj-workspace` 0.1.0,
  `persiyanov.reviewr` 0.24.1, tracked in `plugins.json`.
- No systemd unit — the server starts on demand behind
  `~/.config/herdr/herdr.sock`.

#### Why the claude integration too, when the reference host lacked it

The only reason scratchpad had `claude: not installed` is that it was never run
there — nothing about herdr or Claude Code prevents it. Enabling it is the right
call, with one caveat that had to be checked rather than assumed.

`herdr integration install claude` writes `~/.claude/hooks/herdr-agent-state.sh`
**and registers hook entries in `~/.claude/settings.json`** — a `.sh` sitting in
`hooks/` is inert on its own, because Claude Code only fires hooks listed in
`settings.json`. That is the same file `moshi-hook install` owns.

Verified against the herdr binary's own strings that it does *targeted* entry
management rather than a wholesale rewrite:

```
ensured claude settings at …
no herdr claude hook entries found in …
removed herdr claude hook entries from …
```

So the two coexist. But since both mutate one file, the module pins the order
(`herdr-setup` runs `After=moshi-hook-setup.service`) so the outcome is
reproducible instead of a boot-time race — and **both hook sets must be
re-verified after deploy** (`moshi-hook status` should still report
`claude current`, and `herdr integration status` should report `claude: current`).

**Fix:** new `modules/herdr.nix` (imported by `development`, and available to
`zeroclaw` later) that:
1. writes `~/.config/herdr/config.toml` from Nix (small, fully user-authored —
   a plain `writeText` + copy oneshot, matching the coding-harness convention);
2. runs `herdr integration install opencode` **and `… install claude`** as an
   idempotent oneshot, ordered after `moshi-hook-setup`;
3. leaves the three GitHub plugins to runtime install **unless** you want them
   pinned — the CLI has no obvious `plugin install` subcommand
   (`herdr --help` lists `workspace`/`worktree`/`tab`/`agent`/`pane`, not
   `plugin`), so making those declarative needs a follow-up probe of
   `herdr config`/`herdr api`. ← *needs your call*

### P1-8 · `moshi-hook host setup` — **already satisfied, no work needed**

Scratchpad ran `moshi-hook host setup` (Easy Pair SSH/Mosh), which appended a
`moshi`-commented key to `~/.ssh/authorized_keys` and depends on `mosh`.
Both are already covered by `modules/common.nix`, which `development` imports:

- **The key is not new.** Scratchpad's `moshi` key body is byte-identical to the
  `iPhone` key at `modules/common.nix:112` (both end `…ia7KN/nFIdGH`) —
  `host setup` merely re-added the existing key under its own comment. Nothing
  to commit.
- **mosh is already declarative**: `programs.mosh.enable = true;
  openFirewall = true;` (`modules/common.nix:100-103`) — package *and* UDP range,
  so no `systemPackages` entry and no `allowedUDPPortRanges` are required.

So `moshi-hook host setup` never needs to be run on `development`. **Item dropped
from the execution order.**

> Minor drive-by: the comment at `modules/common.nix:95-99` states
> `openFirewall = false` and explains why no LAN UDP range is opened, but line 102
> actually sets `openFirewall = true`. The comment contradicts the code — worth a
> one-line correction while nearby.

---

## 3. P2 — correctness and polish

### P2-9 · `opencode.json` → `opencode.jsonc` — **decided: use `.jsonc`**

`modules/coding-harness.nix:87` deep-merges its MCP fragment into
`~/.config/opencode/opencode.json`. Scratchpad's actual config file is
`~/.config/opencode/opencode.jsonc` (containing only `$schema`) — so today the
Nix-managed MCP config would land in a file opencode never reads.

**Fix:** change the merge target in `modules/coding-harness.nix` to
`${home}/.config/opencode/opencode.jsonc`.

Caveat to handle while implementing: `mergeJson` uses `jq -s '.[0] * .[1]'`, and
`jq` cannot parse comments. The current file contains none (just `$schema`), so
the merge works as-is — but a hand-added `//` comment would break it. Either seed
the file comment-free and note that in the module, or switch the merge to a
jsonc-tolerant reader. Also delete any stale `opencode.json` the previous
target may have left behind, so there is exactly one config file.

### P2-10 · Dev tooling parity

`development` already has `tmux`. Missing relative to scratchpad: `mosh`, `bun`,
`nodejs`/`npm`. (`cargo` was present on scratchpad but nothing in this harness
needs it — skip unless you want it.)

### P2-11 · ~~`development` is excluded from drift detection~~ — obsolete

Dropped during the rebase onto `main`: `tools/colmena-drift.sh` was removed
wholesale in `a0ba785 chore(tools): remove colmena-drift script, just recipe, and
doc references`, so there is no host list to add `development` to. Drift is now
covered by `just colmena-build-host <host>`.

### P2-12 · Pairing failures are invisible

`moshiPairInstall` exits 0 on both an unreadable secret and a failed pair.
Combined with P0-2 this means "notifications don't work" has no signal anywhere.
Minimum: let the unit fail (drop the `exit 0`s) so activation surfaces it.
Better: a node-exporter textfile metric for `moshi-hook status` paired-ness, since
`hosts/otel` already scrapes this host at `192.168.2.184:9100`.

### P2-13 · The VM is undersized — **disk is the binding constraint**

Measured on scratchpad (2 vCPU, 1955 MiB RAM, 256 GB disk) while running the
real harness:

```
Mem:  1955 total  1372 used  582 available   # opencode peaked at 570 MB RSS; herdr 5 MB; moshi-hook 18 MB
/dev/sda3  256G   22G used (9%)              # of which /nix alone = 21G
```

Against the two IaC definitions:

| | cores | dedicated | floating | disk |
|---|---|---|---|---|
| `scratchpad_vm` (`iac/main.tf:1063`) | 2 | 2048 | 1024 | **256** |
| `development_vm` (`iac/main.tf:938-957`) | 2 | **1024** | 512 | **32** |

**Disk is the real problem.** Scratchpad consumes 22 GB — 69 % of
`development`'s entire 32 GB — and **21 GB of that is `/nix` alone**, on a Fedora
box where Nix is a *side experiment*. On NixOS `/nix` is the whole system, and a
dev host additionally retains multiple system generations plus podman images.
32 GB is not viable. **32 → 256 GB**, matching scratchpad.

**RAM second.** opencode alone peaked at **570 MB RSS**, and total usage hit
1372 of 1955 MiB — with Claude Code *not even running*. `development`'s
1024 MiB dedicated cannot hold opencode plus a concurrent Claude Code (node,
typically 300-600 MB) plus the bun-hosted plugins. **1024 → 4096 MiB dedicated,
floating 2048** — above scratchpad's 2048, since `containers`/`fleet` already sit
at 3584/3072 for lighter work.

**Cores: leave at 2.** `colmenaHive.development` sets `buildOnTarget = false`
(`flake.nix:498-511`), so Nix builds happen on the deploy host, and scratchpad
runs the same workload fine on 2. Bump only if it feels slow in practice.

> **No manual disk growth needed.** `modules/disko-config.nix` sizes root at
> `100%` of a single btrfs partition, and disko only runs during nixos-anywhere —
> so on an incremental `colmena apply` a bigger Proxmox disk would leave the guest
> partition at 32 GB, requiring a hand `growpart` + `btrfs filesystem resize`.
> Since the VM is being **reinstalled** (§5 Phase B), disko repartitions the full
> 256 GB itself and that step disappears. Do the resize *before* the reinstall.

---

## 4. Explicitly out of scope (unless you say otherwise)

- **The standalone home-manager/zsh experiment on scratchpad.**
  `~/.config/home-manager/{home.nix,zsh.nix}` (zsh + powerlevel10k +
  fast-syntax-highlighting + eza/bat aliases, ~7.7 KB) is a *Fedora* port — its
  central `LOCALE_ARCHIVE` workaround exists only because nix-built glibc can't
  find Fedora's locale archive, which is a non-problem on NixOS. The repo already
  has a `homeManagerNixvim` layer applied via `colmenaHive.defaults`. Porting the
  zsh config into that shared layer is a reasonable follow-up but is a separate,
  all-hosts-affecting change. ← *needs your call*
- **Decommissioning `scratchpad`** (`iac/main.tf:1063`, DNS entries at
  `hosts/dns/configuration.nix:122,163`, output at 1295) once `development` is
  verified. ← *needs your call*
- **`osquery.nix`**, which `zeroclaw` imports (`hosts/zeroclaw/configuration.nix:12`)
  and `development` does not. Flagging the inconsistency only.

---

## 5. Execution order — **revised for a nixos-anywhere reinstall**

The `development` VM holds nothing worth keeping, so it gets **reinstalled**
rather than incrementally applied. That removes the manual `growpart` /
`btrfs resize` step (disko repartitions the full 256 GB during the install) and,
per AGENTS.md §6, full `nixos-anywhere .#development` is the correct path for a
static-IP host anyway.

**The reinstall generates a new SSH host key**, which invalidates every agenix
secret encrypted to `hostDevelopment`. So *all* secret work must happen **after**
the install, not before — this is the one scenario where `just reencrypt` is
genuinely warranted (`agenix-reprovision-rekey`, AGENTS.md §6).

### Phase A — repo changes (offline, no deploy)

1. **P0-1** flake fix — unblocks every subsequent `nix eval` / build of this host.
2. **P0-3** moshi-hook 0.2.59 bump + delete the stale project-local comment.
3. **P0-2** moshi-hook → `systemd.user.services` + `users.users.amadeus.linger`.
4. **P1-7** `modules/herdr.nix` (`config.toml` + opencode integration oneshot).
5. **P1-4 / P2-10** `bun` + `nodejs` into `systemPackages`. *(Not `mosh` — already
   provided by `modules/common.nix:100`.)*
6. **P2-9** retarget the opencode merge to `opencode.jsonc`.
7. **P2-12** pairing-failure signal. *(P2-11 dropped — see above.)*
8. **P2-13** `iac/main.tf`: disk 32 → 256 GB, memory 1024 → 4096 / floating 2048.
9. Drive-by: fix the contradictory `openFirewall` comment at
   `modules/common.nix:95-99`.

**P1-8 is dropped** — already satisfied by `modules/common.nix` (see above).

Gate after each Nix change: `just fmt` → `nix eval
.#nixosConfigurations.development…drvPath` → `just colmena-build-host development`.

### Phase B — provision (destructive, needs confirmation)

10. `just iac-apply` — resizes the VM. **Wipes nothing yet**, but restarts it.
11. `just deploy development 192.168.2.184` — **nixos-anywhere, destroys the
    disk**, repartitions the full 256 GB via disko, lands the static IP.

### Phase C — secrets, after the new host key exists

12. `just get-host-key 192.168.2.184` → update `hostDevelopment` at
    `secrets/secrets.nix:22` with the new key.
13. `just reencrypt` — **now correct**, because the host key actually changed.
    This is what restores `axon-gateway-env`, `moshi-device-id`,
    `tailscale-auth-key`, and `fleet-enroll-secret` for this host.
14. **P1-5** per-host opencode key. **You:** mint the key and add
    `secrets/development-opencode-zen-key.age` + its `secrets.nix` entry (contract
    in P1-5 above). **Me:** declare `age.secrets.opencode-zen-key` on the host and
    add the gated auth.json writer to `modules/coding-harness.nix`.
    *Do this after step 13 — a `just reencrypt` run before the new `.age` file
    exists simply won't include it.*
15. `just colmena-apply-host development` — adds the home-manager/nixvim layer
    and applies the secret-dependent units.

### Phase D — manual, one-time

16. `claude login` on the host (per the P1-6 decision).
17. Verify per §6.

## 6. Post-deploy verification (none of this can be checked offline)

- `moshi-hook status` → `status: paired`, and `hooks:` shows `claude current` +
  `opencode current`.
- An actual notification arrives on the iOS Moshi app (start a Claude Code
  session; `SessionStart` fires the hook).
- `herdr integration status` → `opencode: current`.
- `opencode` starts, loads both global plugins without a missing-module error,
  and authenticates.
- `claude` reaches the `axon-gateway` MCP server (confirms
  `AXON_GATEWAY_TOKEN` reached the process).
- Mosh in from the iOS app.
