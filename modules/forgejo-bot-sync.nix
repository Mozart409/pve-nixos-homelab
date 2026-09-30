# Git on behalf of agents that have no shell.
#
# The hermes profiles (eve, heimdall) can read and edit files but cannot run
# git. For each bot this clones its repos under <baseDir>/<bot>/<repo> and, on a
# timer, commits whatever the agent changed, rebases onto upstream and pushes —
# authenticated with THAT bot's own Forgejo SSH key and authored as that bot, so
# every change is attributable and each key is revocable on its own.
#
# Which repos a bot may clone or push is decided in Forgejo (collaborator
# invites, branch-protection whitelists), not here: a repo listed here that the
# bot was never invited to simply fails to clone, and the run moves on.
#
# Never force-pushes. A rebase that conflicts is aborted and left for a human
# (the local commit stays, nothing is lost); the next run tries again.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.forgejoBotSync;

  botType = lib.types.submodule ({name, ...}: {
    options = {
      sshKey = lib.mkOption {
        type = lib.types.str;
        description = "Runtime path of the bot's private key (agenix), readable by `user`.";
      };
      email = lib.mkOption {
        type = lib.types.str;
        default = "${name}@homelab.local";
        description = "Commit author email; match the Forgejo account's email.";
      };
      repos = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {obsidian-kb = "amadeus/obsidian-kb";};
        description = "Checkout directory name → `owner/repo` on Forgejo.";
      };
      commit = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Commit and push local changes. false = pull-only mirror.";
      };
      commitMessage = lib.mkOption {
        type = lib.types.str;
        default = "chore(${name}): sync agent edits";
        description = "Single-line conventional-commit subject for automatic commits.";
      };
    };
  });

  worker = pkgs.writeShellApplication {
    name = "forgejo-bot-sync-worker";
    runtimeInputs = [pkgs.git pkgs.openssh pkgs.coreutils];
    text = ''
      # args: bot email commit(0|1) message dir url
      bot="$1" email="$2" commit="$3" message="$4" dir="$5" url="$6"
      log() { echo "[$bot/$(basename "$dir")] $*"; }

      if [ ! -d "$dir/.git" ]; then
        mkdir -p "$(dirname "$dir")"
        if ! timeout 120 git clone --quiet "$url" "$dir"; then
          log "clone failed (not invited as collaborator yet?), skipping"
          exit 0
        fi
        log "cloned"
      fi
      cd "$dir"
      git config user.name "$bot"
      git config user.email "$email"

      branch="$(git symbolic-ref --quiet --short HEAD || true)"
      if [ -z "$branch" ]; then
        log "detached HEAD, skipping"
        exit 0
      fi
      if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        log "rebase in progress, needs a human"
        exit 0
      fi

      if [ "$commit" = 1 ] && [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit --quiet -m "$message"
        log "committed local changes"
      fi

      if ! timeout 60 git fetch --quiet origin --prune; then
        log "fetch failed, skipping"
        exit 0
      fi
      upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
      if [ -z "$upstream" ]; then
        log "no upstream for $branch"
        exit 0
      fi

      if [ -n "$(git status --porcelain)" ]; then
        log "uncommitted changes in a pull-only checkout, not pulling"
        exit 0
      fi

      if [ "$commit" = 1 ]; then
        if ! git rebase --quiet "$upstream" >/dev/null 2>&1; then
          git rebase --abort || true
          log "rebase onto $upstream conflicts, left for a human"
          exit 0
        fi
        ahead="$(git rev-list --count "$upstream..HEAD")"
        if [ "$ahead" -gt 0 ]; then
          if timeout 120 git push --quiet origin "$branch:$branch"; then
            log "pushed $ahead commit(s)"
          else
            log "push rejected (branch protection / no write access?)"
          fi
        fi
      elif ! git merge --quiet --ff-only "$upstream" >/dev/null 2>&1; then
        log "not fast-forwardable, skipping"
      fi
    '';
  };

  botScript = name: bot:
    pkgs.writeShellScript "forgejo-bot-sync-${name}" ''
      # -F /dev/null: ignore ssh_config entirely, so a host-wide Match block
      # routing Forgejo to another account's key can never win over this one.
      export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -F /dev/null -i ${bot.sshKey} -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
      ${lib.concatStrings (lib.mapAttrsToList (dir: repo: ''
          ${worker}/bin/forgejo-bot-sync-worker ${lib.escapeShellArgs [
            name
            bot.email
            (
              if bot.commit
              then "1"
              else "0"
            )
            bot.commitMessage
            "${cfg.baseDir}/${name}/${dir}"
            "ssh://forgejo@${cfg.forgejoHost}:${toString cfg.forgejoPort}/${repo}.git"
          ]} || echo "[${name}/${dir}] unexpected error"
        '')
        bot.repos)}
    '';
in {
  options.homelab.forgejoBotSync = {
    user = lib.mkOption {
      type = lib.types.str;
      description = "Unix account that owns the checkouts and runs the sync.";
    };
    baseDir = lib.mkOption {
      type = lib.types.str;
      description = "Checkouts live at <baseDir>/<bot>/<repo>.";
    };
    forgejoHost = lib.mkOption {
      type = lib.types.str;
      default = "forgejo.homelab.local";
    };
    forgejoPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "systemd time span between syncs.";
    };
    bots = lib.mkOption {
      type = lib.types.attrsOf botType;
      default = {};
    };
  };

  config = lib.mkIf (cfg.bots != {}) {
    systemd.services.forgejo-bot-sync = {
      description = "Clone, commit, rebase and push the Forgejo bot checkouts (never forces)";
      after = ["network-online.target" "agenix.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # Group-writable, like the rest of the hermes state tree.
        UMask = "0007";
        ExecStart = lib.mapAttrsToList botScript cfg.bots;
      };
    };
    systemd.timers.forgejo-bot-sync = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
      };
    };
  };
}
