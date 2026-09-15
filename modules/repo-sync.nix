# Periodic git sync of every checkout under a user's ~/code.
#
# Two instances on the development host since the agent/human split
# (2026-09-14, see modules/agent-user.nix):
#   agent   -- fetch, fast-forward pull, AND push, with the agent's Forgejo key
#              (agenix `agent-forgejo-ssh`). This is how agent commits reach
#              Forgejo without a human step.
#   amadeus -- fetch + fast-forward pull ONLY. That clone is where the human
#              runs `just self-deploy`; it follows main and never publishes
#              whatever half-finished state a person left in it.
# The old single instance ran as amadeus with push, using ~amadeus/.ssh's
# unencrypted key -- which, with the agents running as amadeus, meant every
# agent commit went out under the human's identity with nothing in between.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.repoSync;

  # Runs inside ONE repo. Never commits, never rebases, never force-pushes:
  # fetch (read-only) -> merge --ff-only (refuses on any divergence, touches
  # nothing but the ref + working tree via a genuine fast-forward) -> plain
  # push (git itself refuses a non-fast-forward push without --force, so
  # omitting the flag IS the safety, not an extra check we have to get right).
  # Exits 0 on every expected/skippable state (dirty tree, detached HEAD, no
  # upstream, diverged, nothing to push) so a normal steady-state repo never
  # counts as a failure; only a genuinely unexpected git error propagates
  # non-zero. REPO_SYNC_PUSH=0 turns the push step off for pull-only instances.
  worker = pkgs.writeShellApplication {
    name = "repo-sync-worker";
    runtimeInputs = [pkgs.git pkgs.coreutils];
    text = ''
      repo="$1"
      name="$(basename "$repo")"
      log() { echo "[$name] $*"; }

      cd "$repo"

      branch="$(git symbolic-ref --quiet --short HEAD || true)"
      if [ -z "$branch" ]; then
        log "detached HEAD, skipping"
        exit 0
      fi

      dirty=""
      [ -n "$(git status --porcelain --untracked-files=no)" ] && dirty=1

      if ! timeout 60 git fetch origin --prune --quiet; then
        log "fetch failed, skipping"
        exit 0
      fi

      upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
      if [ -z "$upstream" ]; then
        log "no upstream for $branch, nothing to pull/push"
        exit 0
      fi

      if [ -n "$dirty" ]; then
        log "uncommitted changes, skipping pull (fetched only)"
      elif merge_out="$(git merge --ff-only "$upstream" 2>&1)"; then
        log "pulled: $merge_out"
      else
        log "not fast-forwardable, skipping pull"
      fi

      if [ "''${REPO_SYNC_PUSH:-1}" != 1 ]; then
        exit 0
      fi

      ahead="$(git rev-list --count "$upstream..HEAD")"
      if [ "$ahead" -eq 0 ]; then
        log "nothing to push"
        exit 0
      fi

      # No --force, ever. A lefthook pre-push hook may run here and can be
      # slow, hence the generous timeout instead of a tight one.
      if timeout 300 git push origin "$branch:$branch"; then
        log "pushed $ahead commit(s)"
      else
        log "push failed or rejected (diverged / hook / auth) -- see above"
      fi
    '';
  };

  # Fans the worker out over every repo under <home>/code, bounded to 4
  # concurrent so lefthook's pre-push hooks don't serialize the whole sweep
  # but also don't hammer the Forgejo host. Uses the instance's key
  # explicitly with BatchMode so a wedged/misconfigured key fails fast
  # instead of hanging the unit on a prompt that will never come (there is
  # no TTY here).
  mkDispatch = name: inst:
    pkgs.writeShellApplication {
      name = "repo-sync-dispatch-${name}";
      runtimeInputs = [pkgs.findutils pkgs.openssh];
      text = ''
        export GIT_SSH_COMMAND="ssh -i ${inst.sshKey} -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
        export REPO_SYNC_PUSH=${
          if inst.push
          then "1"
          else "0"
        }

        find "${inst.home}/code" -mindepth 1 -maxdepth 1 -type d -exec test -d {}/.git \; -print0 \
          | xargs -0 -r -P 4 -n 1 ${worker}/bin/repo-sync-worker \
          || echo "repo-sync: one or more repos reported a problem (see log above)"
      '';
    };

  mkService = name: inst: {
    description = "Fetch/fast-forward-pull${lib.optionalString inst.push " and push"} every git repo under ${inst.home}/code (never commits, never forces)";
    after = ["network-online.target" "agenix.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = inst.user;
      RuntimeDirectory = "repo-sync-${name}";
      # Skip this run instead of piling up if a previous one (e.g. a slow
      # lefthook pre-push hook) is still going when the timer fires again.
      ExecStart = "${pkgs.util-linux}/bin/flock -n /run/repo-sync-${name}/lock ${mkDispatch name inst}/bin/repo-sync-dispatch-${name}";
      # The development host has a documented history of IO contention from
      # concurrent background work (see its zramSwap comment) -- keep this
      # sweep low priority relative to interactive/agent sessions.
      Nice = 10;
    };
  };

  mkTimer = name: _: {
    description = "Periodic ~/code repo sync (${name})";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "20min";
      AccuracySec = "1min";
    };
  };
in {
  options.homelab.repoSync = lib.mkOption {
    default = {};
    description = "repo-sync instances, one per user whose ~/code should follow Forgejo.";
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        user = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Login the sweep runs as.";
        };
        home = lib.mkOption {
          type = lib.types.str;
          default = "/home/${name}";
          description = "Home directory; the sweep covers <home>/code/*.";
        };
        sshKey = lib.mkOption {
          type = lib.types.str;
          description = "Private key for the Forgejo remote (unencrypted or agenix-decrypted; BatchMode).";
        };
        push = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Push local commits after the fast-forward pull. Off = pull-only mirror.";
        };
      };
    }));
  };

  config = {
    systemd.services = lib.mapAttrs' (name: inst: lib.nameValuePair "repo-sync-${name}" (mkService name inst)) cfg;
    systemd.timers = lib.mapAttrs' (name: inst: lib.nameValuePair "repo-sync-${name}" (mkTimer name inst)) cfg;
  };
}
