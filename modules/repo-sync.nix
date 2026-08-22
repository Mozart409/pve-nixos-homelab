{pkgs, ...}: let
  home = "/home/amadeus";
  reposDir = "${home}/code";
  syncUser = "amadeus";

  # Runs inside ONE repo. Never commits, never rebases, never force-pushes:
  # fetch (read-only) -> merge --ff-only (refuses on any divergence, touches
  # nothing but the ref + working tree via a genuine fast-forward) -> plain
  # push (git itself refuses a non-fast-forward push without --force, so
  # omitting the flag IS the safety, not an extra check we have to get right).
  # Exits 0 on every expected/skippable state (dirty tree, detached HEAD, no
  # upstream, diverged, nothing to push) so a normal steady-state repo never
  # counts as a failure; only a genuinely unexpected git error propagates
  # non-zero.
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

  # Fans the worker out over every repo under ~/code, bounded to 4 concurrent
  # so lefthook's pre-push hooks don't serialize the whole sweep but also
  # don't hammer the Forgejo host. Uses the developmentbot key explicitly with
  # BatchMode so a wedged/misconfigured key fails fast instead of hanging the
  # unit on a prompt that will never come (there is no TTY here).
  dispatch = pkgs.writeShellApplication {
    name = "repo-sync-dispatch";
    runtimeInputs = [pkgs.findutils pkgs.openssh];
    text = ''
      export GIT_SSH_COMMAND="ssh -i ${home}/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

      find "${reposDir}" -mindepth 1 -maxdepth 1 -type d -exec test -d {}/.git \; -print0 \
        | xargs -0 -r -P 4 -n 1 ${worker}/bin/repo-sync-worker \
        || echo "repo-sync: one or more repos reported a problem (see log above)"
    '';
  };
in {
  systemd.services.repo-sync = {
    description = "Fetch/fast-forward-pull and push every git repo under ~/code (never commits, never forces)";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = syncUser;
      RuntimeDirectory = "repo-sync";
      # Skip this run instead of piling up if a previous one (e.g. a slow
      # lefthook pre-push hook) is still going when the timer fires again.
      ExecStart = "${pkgs.util-linux}/bin/flock -n /run/repo-sync/lock ${dispatch}/bin/repo-sync-dispatch";
      # This host has a documented history of IO contention from concurrent
      # background work (see zramSwap comment above) -- keep this sweep low
      # priority relative to interactive/agent sessions.
      Nice = 10;
    };
  };

  systemd.timers.repo-sync = {
    description = "Periodic ~/code repo sync";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "20min";
      AccuracySec = "1min";
    };
  };
}
