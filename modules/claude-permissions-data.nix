# Canonical Claude Code permission rules for the amadeus user.
#
# Plain data, imported by BOTH modules/claude-permissions.nix (which applies it)
# and modules/claude-settings-verify.nix (which checks it survived). Keeping one
# copy is the whole point: this repo already fights drift in ~/.claude/settings.json,
# and two hand-maintained deny lists would be a new source of it.
#
# Rule syntax is Claude Code's own: `Tool(pattern)`, where a trailing `*` is a
# prefix match and `Sub(cmd:*)` matches a subcommand and everything after it.
# Precedence is deny > ask > allow, so a broad allow below is still narrowed by
# any matching deny — that is how `git push` is granted without granting
# `git push --force`.
{
  # Domains WebSearch may be restricted to. WebSearch permission rules accept no
  # domain specifier, so this list is the single source for two enforcement
  # points: the PreToolUse hook in modules/claude-permissions.nix (which refuses
  # any search whose allowed_domains is not a subset of this list) and the
  # WebFetch allow rules above (which restrict which result pages Claude may
  # read). Keep both in lockstep — they are one boundary.
  webSearchDomains = [
    "nixos.org"
    "nix.dev"
    "discourse.nixos.org"
    "github.com"
    "stackoverflow.com"
    "code.claude.com"
  ];

  # Without an allow list and with defaultMode = "dontAsk", every state-changing
  # command is refused silently. These are the ones routine work needs — the set
  # below is what sessions actually accumulated by hand before this file took
  # over, so nothing here is speculative.
  allow = [
    # Git. `push` is narrowed by the deny list below: no force-push.
    "Bash(git add:*)"
    "Bash(git branch:*)"
    "Bash(git checkout:*)"
    "Bash(git commit:*)"
    "Bash(git diff:*)"
    "Bash(git fetch:*)"
    "Bash(git log:*)"
    "Bash(git merge:*)"
    "Bash(git mv:*)"
    "Bash(git pull:*)"
    "Bash(git push:*)"
    "Bash(git restore:*)"
    "Bash(git rm:*)"
    "Bash(git show:*)"
    "Bash(git stash:*)"
    "Bash(git status:*)"
    "Bash(git switch:*)"
    "Bash(git tag:*)"

    # Forges, task runners, toolchains.
    "Bash(gh:*)"
    "Bash(nix:*)"
    "Bash(just:*)"
    "Bash(lefthook:*)"
    "Bash(go:*)"
    "Bash(make:*)"
    "Bash(pnpm:*)"

    # Rust.
    "Bash(cargo:*)"
    "Bash(rustc:*)"
    "Bash(rustup:*)"
    "Bash(rustfmt:*)"
    "Bash(bacon:*)"

    # Containers and databases.
    "Bash(docker:*)"
    "Bash(podman:*)"
    "Bash(podman-compose:*)"
    "Bash(psql:*)"
    "Bash(pg_isready:*)"
    "Bash(sqlx:*)"
    "Bash(sqruff:*)"

    # Web research. WebSearch permission rules take NO specifier — a bare
    # `WebSearch` is the only form Claude Code accepts (no domain filter, no
    # wildcards), so "no arbitrary websearch" cannot be a permission rule. It is
    # enforced by a PreToolUse hook (written by modules/claude-permissions.nix)
    # that refuses any WebSearch call whose allowed_domains is not a subset of
    # webSearchDomains above, plus the WebFetch domain rules underneath, which
    # are the only domains Claude may read result pages from. Keep the allow
    # list here and webSearchDomains in lockstep — they are one boundary.
    "WebSearch"
    "WebFetch(domain:nixos.org)"
    "WebFetch(domain:nix.dev)"
    "WebFetch(domain:discourse.nixos.org)"
    "WebFetch(domain:github.com)"
    "WebFetch(domain:stackoverflow.com)"
    "WebFetch(domain:code.claude.com)"

    # MCP servers. Only the tools that are actually used are allowed — dontAsk
    # denies every unlisted MCP call silently, so without a rule a needed tool
    # looks broken rather than permission-blocked. Both server-level wildcards
    # (mcp__<server>__*) and exact tool names are valid allow forms; a bare
    # `mcp__*` allow is skipped by Claude Code with a warning and approves
    # nothing, so every server is named explicitly.
    #
    # axon-gateway (modules/coding-harness.nix) is the central gateway exposing
    # Home Assistant, Loki, Prometheus, PBS and Postgres tools — all of them.
    # internal-dashboard is added per-host and exposes its full tool set too.
    "mcp__axon-gateway__*"
    "mcp__internal-dashboard__*"

    # Service and log inspection. AGENTS.md §5's post-deploy checklist is built
    # on `journalctl -u <unit>` and `systemctl status`, but neither had a rule
    # here, so dontAsk denied them *silently* — the checklist the repo asks for
    # could not actually be run, and a failed unit read as a broken tool rather
    # than a missing permission.
    #
    # Read-only verbs ONLY. start/stop/restart/enable/disable stay unlisted (and
    # so denied) because this VM is shared with other agent sessions, where
    # bouncing a unit out from under someone is the same class of harm as the
    # reboot rules in the deny list.
    #
    # These are prefix matches, so the bare and `--user` spellings are separate
    # entries: `systemctl --user status x` does not match `Bash(systemctl
    # status:*)`. herdr-setup and moshi-hook-setup are user units, so the
    # `--user` half is the half that matters for those.
    "Bash(systemctl status:*)"
    "Bash(systemctl show:*)"
    "Bash(systemctl cat:*)"
    "Bash(systemctl list-units:*)"
    "Bash(systemctl list-unit-files:*)"
    "Bash(systemctl is-active:*)"
    "Bash(systemctl is-enabled:*)"
    "Bash(systemctl is-failed:*)"
    "Bash(systemctl --user status:*)"
    "Bash(systemctl --user show:*)"
    "Bash(systemctl --user cat:*)"
    "Bash(systemctl --user list-units:*)"
    "Bash(systemctl --user list-unit-files:*)"
    "Bash(systemctl --user is-active:*)"
    "Bash(systemctl --user is-enabled:*)"
    "Bash(systemctl --user is-failed:*)"
    # journalctl is read-only apart from its log-pruning flags, which the deny
    # list blocks; a single broad rule beats enumerating -u/-b/-n/--user forms.
    "Bash(journalctl:*)"

    # Shell basics. A compound command is refused unless EVERY segment is
    # allowed, so cd and friends must be listed even though they change
    # nothing on their own.
    "Bash(cat:*)"
    "Bash(cd:*)"
    "Bash(cp:*)"
    "Bash(curl:*)"
    "Bash(echo:*)"
    "Bash(file:*)"
    "Bash(find:*)"
    "Bash(grep:*)"
    "Bash(head:*)"
    "Bash(jq:*)"
    "Bash(ls:*)"
    "Bash(mkdir:*)"
    "Bash(mv:*)"
    "Bash(pwd)"
    "Bash(rg:*)"
    "Bash(tail:*)"
    "Bash(timeout:*)"
    "Bash(touch:*)"
    "Bash(tree:*)"
    "Bash(wc:*)"
    "Bash(which:*)"
    "Bash(yq:*)"

    # Subagents. Explore/Plan/General-purpose — spawned through the Agent tool —
    # check their tool calls against this same allow list, but only *narrow*
    # `Bash(<cmd>:*)` rules flow to them: a bare `Bash` / `Bash(*)` allow is
    # unreliable for subagents and is stripped entirely when auto mode is active
    # (the classifier evaluates shell commands then). These cover what a delegated
    # agent runs that is not already granted above and hold in both dontAsk
    # (unattended) and auto (interactive) sessions. They are session-wide, so the
    # main agent gains them too; the deny list still governs.
    "Bash(awk:*)"
    "Bash(bash:*)"
    "Bash(cut:*)"
    "Bash(diff:*)"
    "Bash(env:*)"
    "Bash(node:*)"
    "Bash(npm:*)"
    "Bash(npx:*)"
    "Bash(python3:*)"
    "Bash(sed:*)"
    "Bash(sh:*)"
    "Bash(sleep:*)"
    "Bash(sort:*)"
    "Bash(stat:*)"
    "Bash(tr:*)"
    "Bash(uniq:*)"
    "Bash(xargs:*)"

    # The workspace itself. Secret files under it are carved back out by the
    # deny list below.
    "Read(//home/amadeus/code/**)"
    "Write(//home/amadeus/code/**)"
    "Edit(//home/amadeus/code/**)"
  ];

  # Grouped by what they protect, not sorted — the grouping is the documentation.
  deny = [
    # Credentials. Read-denied rather than merely ask-gated: an agent has no
    # legitimate reason to read a private key, and a prompt is a decision the
    # user would have to get right every single time.
    "Read(//home/amadeus/.ssh/**)"
    "Read(//home/amadeus/.claude/.credentials.json)"
    "Read(//home/amadeus/.aws/**)"
    "Read(//home/amadeus/.config/gh/**)"
    "Edit(//home/amadeus/.ssh/**)"

    # Secret files inside the workspace. The allow list grants broad
    # Read/Write/Edit on ~/code, so the secret patterns must be carved back
    # out explicitly. This binds shell commands too: the Bash engine checks
    # file paths in a command against these rules, which is how
    # `cp .env.example .env` is refused without refusing `cp` itself.
    "Read(//home/amadeus/code/**/.env)"
    "Read(//home/amadeus/code/**/.env.*)"
    "Read(//home/amadeus/code/**/*.env)"
    "Read(//home/amadeus/code/**/secrets/**)"
    "Read(//home/amadeus/code/**/.secrets/**)"
    "Read(//home/amadeus/code/**/*.pem)"
    "Read(//home/amadeus/code/**/*.key)"
    "Read(//home/amadeus/code/**/id_rsa*)"
    "Read(//home/amadeus/code/**/id_ed25519*)"
    "Read(//home/amadeus/code/**/credentials*)"
    "Write(//home/amadeus/code/**/.env)"
    "Write(//home/amadeus/code/**/.env.*)"
    "Write(//home/amadeus/code/**/*.env)"
    "Write(//home/amadeus/code/**/secrets/**)"
    "Write(//home/amadeus/code/**/.secrets/**)"
    "Write(//home/amadeus/code/**/*.pem)"
    "Write(//home/amadeus/code/**/*.key)"
    "Write(//home/amadeus/code/**/id_rsa*)"
    "Write(//home/amadeus/code/**/id_ed25519*)"
    "Write(//home/amadeus/code/**/credentials*)"
    "Edit(//home/amadeus/code/**/.env)"
    "Edit(//home/amadeus/code/**/.env.*)"
    "Edit(//home/amadeus/code/**/*.env)"
    "Edit(//home/amadeus/code/**/secrets/**)"
    "Edit(//home/amadeus/code/**/.secrets/**)"
    "Edit(//home/amadeus/code/**/*.pem)"
    "Edit(//home/amadeus/code/**/*.key)"
    "Edit(//home/amadeus/code/**/id_rsa*)"
    "Edit(//home/amadeus/code/**/id_ed25519*)"
    "Edit(//home/amadeus/code/**/credentials*)"

    # Destructive filesystem operations.
    "Bash(sudo rm *)"
    "Bash(rm -rf /*)"
    "Bash(rm -rf ~*)"
    "Bash(mkfs*)"
    "Bash(dd if=* of=/dev/*)"
    "Bash(sudo dd*)"

    # Host lifecycle. This is a VM other agents' sessions share; a reboot from
    # one session kills all of them.
    "Bash(shutdown*)"
    "Bash(reboot*)"
    "Bash(poweroff*)"
    "Bash(halt*)"
    "Bash(systemctl reboot*)"
    "Bash(systemctl poweroff*)"

    # Journal integrity. `Bash(journalctl:*)` is allowed for the post-deploy
    # checklist; these are its only non-read-only flags, and deleting logs would
    # destroy the evidence another session is mid-debug on.
    "Bash(journalctl --vacuum*)"
    "Bash(journalctl --rotate*)"
    "Bash(sudo journalctl --vacuum*)"
    "Bash(sudo journalctl --rotate*)"

    # Nix store integrity. GC while another session is mid-build breaks it.
    "Bash(nix-collect-garbage*)"
    "Bash(nix store delete*)"
    "Bash(nix-store --delete*)"

    # Deploys. Agents write configuration in this repo; applying it is a human
    # decision, and nixos-rebuild from inside a session can cut its own network.
    "Bash(nixos-rebuild*)"
    "Bash(sudo nixos-rebuild*)"
    "Bash(nixos-install*)"
    "Bash(sudo nixos-install*)"
    "Bash(nh os*)"
    "Bash(sudo nh*)"
    "Bash(nh home*)"
    "Bash(home-manager switch*)"
    "Bash(colmena apply*)"
    "Bash(deploy *)"
    "Bash(nixops *)"

    # The same deploys reached through the task runner. `Bash(just:*)` in the
    # allow list is matched against the literal command line, not against what
    # the recipe expands to, so `just ca` walks straight past the
    # `Bash(colmena apply*)` deny above. Every wrapper needs its own entry.
    # Builds stay allowed — `just cb` / `just colmena-build` touch nothing.
    "Bash(just ca*)"
    "Bash(just colmena-apply*)"
    "Bash(just colmena-reboot*)"
    "Bash(just deploy*)"

    # Irreversible git/forge actions. Narrows the Bash(git push:*) allow above:
    # a force-push can destroy history that exists nowhere else, and merging is
    # the one step in the PR flow that should stay human.
    "Bash(git push --force*)"
    "Bash(git push -f*)"
    "Bash(gh pr merge*)"
  ];

  # Unattended agent sessions are the normal case on this host, so prompts that
  # nobody is present to answer would just hang. The deny list above is what
  # makes that safe: it is the guardrail, not the prompt.
  defaultMode = "dontAsk";
}
