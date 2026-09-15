# The unattended-coding-agent account and the one place its identity is named.
#
# Every module that sets up an agent harness (modules/coding-harness.nix,
# herdr.nix, claude-permissions.nix, claude-settings-verify.nix,
# moshi-hook-user.nix, repo-sync.nix) reads `config.homelab.agent.{user,home}`
# instead of hardcoding a login, so switching the account is one attribute.
#
# Why a separate account at all (2026-09-14): the agents used to run as
# `amadeus`, who is in wheel with passwordless sudo on every host
# (modules/common.nix). Claude Code's deny list is enforced by the client and
# was trivially bypassable (`bash -c`, `env`, `xargs`, ...), so the only
# guardrail that actually held was "nobody is watching". Running the agents as
# a user with no sudo at all makes the OS the boundary: an agent can edit and
# push this repo, but only a human as `amadeus` can `just self-deploy` it.
#
# The agent still commits and pushes with your Forgejo identity -- that is
# deliberate, main is meant to be pushable from here (see hosts/development).
# The key it uses is the agenix secret `agent-forgejo-ssh`, not
# ~amadeus/.ssh, which it cannot read.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.agent;
in {
  options.homelab.agent = {
    enable = lib.mkEnableOption "the dedicated unattended-agent user account";
    user = lib.mkOption {
      type = lib.types.str;
      default = "agent";
      description = "Login the coding-agent harness modules configure.";
    };
    home = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}";
      description = "Home directory of that login.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Plain users.users rather than homelab.users: this reads amadeus's keys
    # from homelab.users, and a homelab.users entry reading homelab.users would
    # be an infinite recursion. Not in wheel -- that is the whole point. The
    # `podman` supplementary group is not needed for rootless podman; the
    # subuid/subgid range isNormalUser allocates is.
    users.users.${cfg.user} = {
      isNormalUser = true;
      home = cfg.home;
      description = "Unattended coding agents (Claude Code, opencode, crush)";
      shell = pkgs.zsh;
      # Same keys as amadeus so you can `ssh agent@<host>` / mosh straight
      # into the agent's herdr session. `sudo -u ${cfg.user} -i` from amadeus
      # works too.
      openssh.authorizedKeys.keys = config.homelab.users.amadeus.sshKeys;
      # User services (claude-permissions, herdr-setup, moshi-hook) start at
      # boot without a login.
      linger = true;
    };

    # The agent's Forgejo key. You create this one by pasting your existing
    # collaborator key:  cd secrets && agenix -e agent-forgejo-ssh.age
    age.secrets.agent-forgejo-ssh = {
      file = ../secrets/agent-forgejo-ssh.age;
      owner = cfg.user;
      mode = "0400";
    };

    # Route every Forgejo name (LAN and tailnet, the origin URL uses the
    # latter) to that key for this user only. `Match` must precede the `Host`
    # blocks the host config appends, and ssh takes the first value it finds,
    # so this wins for the agent while amadeus keeps ~/.ssh/id_ed25519.
    programs.ssh.extraConfig = lib.mkBefore ''
      Match user ${cfg.user} host forgejo.homelab.local,forgejo.homelab.internal,homelab-forgejo.dropbear-butterfly.ts.net
        Port 2222
        User forgejo
        IdentityFile ${config.age.secrets.agent-forgejo-ssh.path}
        IdentitiesOnly yes
        IdentityAgent none
        StrictHostKeyChecking accept-new
    '';

    # No sudo, no exceptions: an explicit deny so a later `extraRules` cannot
    # quietly widen it, and so `sudo -l` as the agent says so in words.
    security.sudo.extraRules = [
      {
        users = [cfg.user];
        commands = [{command = "!ALL";}];
      }
    ];
  };
}
