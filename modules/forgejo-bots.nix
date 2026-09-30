# Declarative bot / LLM accounts on this Forgejo instance.
#
#   homelab.forgejoBots.eve.sshPublicKeys.hermes = "ssh-ed25519 AAAA…";
#
# A oneshot after forgejo.service makes sure each declared account exists and
# holds exactly the declared SSH keys. It does NOT grant repo access: invite
# each bot as a collaborator in the web UI — that invitation IS the access
# gate, and it stays a human decision.
#
# How it authenticates without a stored admin token: the forgejo CLI talks to
# the database directly, so each run sets the bot's password to a fresh random
# value (never written anywhere), uses it for basic-auth API calls that manage
# the bot's own keys, and exits. Nobody knows a bot's password afterwards; bots
# authenticate with their SSH keys only.
#
# Keys are reconciled by title: every key this module adds is titled
# `nix:<name>`, and `nix:` keys that are no longer declared are deleted. Keys
# added by hand (any other title) are left alone. Removing a bot from this
# attrset does NOT delete the account — delete it in the web UI.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.forgejoBots;
  fjCfg = config.services.forgejo;
  fjUnit = config.systemd.services.forgejo;
  apiUrl = "http://${fjCfg.settings.server.HTTP_ADDR}:${toString fjCfg.settings.server.HTTP_PORT}/api/v1";

  botType = lib.types.submodule ({name, ...}: {
    options = {
      email = lib.mkOption {
        type = lib.types.str;
        default = "${name}@homelab.local";
        description = "Account email (must be unique on the instance).";
      };
      fullName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Display name.";
      };
      restricted = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Create the account as restricted: it sees only repos it is explicitly
          a collaborator on, not every public/internal repo. Applied at
          creation only; an existing account keeps its current flag.
        '';
      };
      sshPublicKeys = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {hermes = "ssh-ed25519 AAAA… eve@hermes";};
        description = "SSH public keys, keyed by a short title (stored as `nix:<title>`).";
      };
    };
  });

  reconcileBot = name: bot: let
    keysJson = pkgs.writeText "forgejo-bot-${name}-keys.json" (builtins.toJSON (
      lib.mapAttrsToList (title: key: {
        title = "nix:${title}";
        key = lib.trim key;
      })
      bot.sshPublicKeys
    ));
  in ''
    reconcile_bot() {
      name=${lib.escapeShellArg name}
      if ! forgejo admin user list | awk 'NR > 1 { print $2 }' | grep -qxF "$name"; then
        forgejo admin user create \
          --username "$name" \
          --email ${lib.escapeShellArg bot.email} \
          --fullname ${lib.escapeShellArg bot.fullName} \
          --random-password --random-password-length 48 \
          --must-change-password=false ${lib.optionalString bot.restricted "--restricted"} \
          >/dev/null # it prints the generated password; never let that reach the journal
        echo "$name: created"
      fi

      pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
      forgejo admin user change-password --username "$name" --password "$pw" --must-change-password=false >/dev/null

      api() { curl -fsS --retry 3 -u "$name:$pw" -H 'Content-Type: application/json' "$@"; }

      have="$(api "${apiUrl}/user/keys?limit=50")"
      # Add declared keys whose key material is not registered yet.
      jq -c '.[]' ${keysJson} | while read -r want; do
        material="$(jq -r '.key | split(" ")[0:2] | join(" ")' <<<"$want")"
        if ! jq -e --arg m "$material" 'any(.[]; (.key | split(" ")[0:2] | join(" ")) == $m)' <<<"$have" >/dev/null; then
          api -X POST "${apiUrl}/user/keys" -d "$want" >/dev/null
          echo "$name: added key $(jq -r .title <<<"$want")"
        fi
      done
      # Drop nix-managed keys that are no longer declared.
      jq -r --slurpfile want ${keysJson} '
        ($want[0] | map(.key | split(" ")[0:2] | join(" "))) as $keep
        | .[] | select(.title | startswith("nix:"))
        | select((.key | split(" ")[0:2] | join(" ")) as $k | $keep | index($k) | not)
        | "\(.id) \(.title)"' <<<"$have" | while read -r id title; do
        api -X DELETE "${apiUrl}/user/keys/$id" >/dev/null
        echo "$name: removed key $title"
      done
      echo "$name: keys in sync"
    }
    reconcile_bot || { echo "${name}: reconcile FAILED" >&2; failed=1; }
  '';
in {
  options.homelab.forgejoBots = lib.mkOption {
    type = lib.types.attrsOf botType;
    default = {};
    description = "Bot accounts provisioned on this Forgejo instance (see module header).";
  };

  config = lib.mkIf (cfg != {}) {
    systemd.services.forgejo-bots = {
      description = "Provision Forgejo bot accounts and their SSH keys";
      after = ["forgejo.service"];
      requires = ["forgejo.service"];
      wantedBy = ["multi-user.target"];
      path = [fjCfg.package pkgs.curl pkgs.jq pkgs.gawk pkgs.gnugrep pkgs.coreutils];
      # The CLI needs the same app.ini and the same credential files the server
      # reads (the DB password et al. arrive via LoadCredential as %d/…).
      # PATH is dropped: `path` above sets this unit's own.
      environment = builtins.removeAttrs fjUnit.environment ["PATH"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = fjCfg.user;
        Group = fjCfg.group;
        WorkingDirectory = fjCfg.stateDir;
        LoadCredential = fjUnit.serviceConfig.LoadCredential or [];
      };
      script = ''
        set -uo pipefail
        failed=0
        # The API comes up a moment after the unit reports started.
        for _ in $(seq 30); do
          curl -fsS -o /dev/null ${apiUrl}/version && break
          sleep 2
        done
        ${lib.concatStrings (lib.mapAttrsToList reconcileBot cfg)}
        exit "$failed"
      '';
    };
  };
}
