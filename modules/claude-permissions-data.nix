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
  # command is refused silently. These are the ones routine work needs.
  allow = [
    "Bash(git checkout:*)"
    "Bash(git branch:*)"
    "Bash(git push:*)"
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
