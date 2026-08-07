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
