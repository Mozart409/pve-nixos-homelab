{pkgs, ...}: let
  user = "amadeus";
  home = "/home/amadeus";

  perms = import ./claude-permissions-data.nix;

  # Only the permissions block and the WebSearch restriction hook, as JSON.
  # Merged into settings.json rather than written as the whole file:
  # modules/herdr.nix and modules/moshi-hook-user.nix own the rest of the
  # `hooks` key there, and Claude Code itself writes UI state into it.
  permsJson = builtins.toJSON {
    permissions = {
      inherit (perms) allow deny defaultMode;
    };
  };

  # WebSearch is all-or-nothing at the permission level (bare `WebSearch` is the
  # only rule form Claude Code accepts), so "no arbitrary websearch" has to be a
  # hook. This one refuses any search whose allowed_domains is not a non-empty
  # subset of webSearchDomains, and refuses blocked_domains entirely (negative
  # scoping cannot be reconciled with a whitelist). The WebFetch allow rules in
  # claude-permissions-data.nix back it up: they are the only domains Claude may
  # read the result pages from. Both derive from the same list.
  websearchHook = pkgs.writeShellApplication {
    name = "claude-websearch-hook";
    runtimeInputs = [pkgs.jq];
    text = ''
      WHITELIST="${builtins.concatStringsSep " " perms.webSearchDomains}"

      input=$(cat)

      # allowed_domains is mandatory, must be an array, and must name at least
      # one host — an empty array is an unscoped search wearing a whitelist hat.
      if ! jq -e '.tool_input.allowed_domains | type == "array" and length > 0' <<<"$input" >/dev/null 2>&1; then
        echo "Blocked: WebSearch must set allowed_domains to a subset of: $WHITELIST" >&2
        exit 2
      fi

      # blocked_domains opts out of the whitelist; not allowed.
      if jq -e '.tool_input.blocked_domains != null' <<<"$input" >/dev/null 2>&1; then
        echo "Blocked: WebSearch must use allowed_domains (whitelist), not blocked_domains: $WHITELIST" >&2
        exit 2
      fi

      # Every requested host must be whitelisted. `.` is rebound by the $w
      # pipeline, so capture each host in a variable before membership-testing.
      bad=$(jq -r --arg w "$WHITELIST" '
        [ .tool_input.allowed_domains[]
          | . as $d
          | select( ($w | split(" ") | index($d)) | not )
        ] | join(", ")
      ' <<<"$input")
      if [ -n "$bad" ]; then
        echo "Blocked: WebSearch allowed_domains not in whitelist ($WHITELIST): $bad" >&2
        exit 2
      fi

      exit 0
    '';
  };

  # The hook, as a matcher group. Merged into .hooks.PreToolUse, replacing any
  # previous group with this matcher so a store path from an older build cannot
  # linger.
  hooksJson = builtins.toJSON {
    hooks = {
      PreToolUse = [
        {
          matcher = "WebSearch";
          hooks = [
            {
              type = "command";
              command = "${websearchHook}/bin/claude-websearch-hook";
            }
          ];
        }
      ];
    };
  };

  # Why a service that edits a mutable file instead of an environment.etc or
  # home-manager file: ~/.claude/settings.json cannot be Nix-owned. Two setup
  # services rewrite their hook entries into it at every boot, and Claude Code
  # mutates it at runtime, so a read-only symlink into /nix/store would either
  # break those writers or be clobbered by them. Owning one *key* is the most
  # Nix can hold here.
  #
  # Until now nothing created permissions.deny at all — it was a hand-edit that
  # modules/claude-settings-verify.nix could only report as missing after the
  # fact. This closes that loop: the verifier detects, this restores.
  apply = pkgs.writeShellApplication {
    name = "claude-permissions-apply";
    runtimeInputs = [pkgs.jq];
    text = ''
      SETTINGS="''${CLAUDE_SETTINGS:-${home}/.claude/settings.json}"
      mkdir -p "$(dirname "$SETTINGS")"

      # A fresh host has no settings.json until Claude Code first runs, and an
      # earlier boot may have left it corrupt. Either way, start from an empty
      # object rather than failing — the permissions block is exactly what must
      # not be missing.
      if [ ! -s "$SETTINGS" ] || ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        echo '{}' > "$SETTINGS"
      fi

      tmp=$(mktemp "$SETTINGS.XXXXXX")
      trap 'rm -f "$tmp"' EXIT

      # `+` is a right-biased shallow merge, so allow/deny/defaultMode are
      # replaced wholesale (a stale rule cannot linger) while any other key under
      # .permissions — additionalDirectories, say — is preserved. Everything
      # outside .permissions is untouched.
      #
      # The hooks merge is deliberately scoped to PreToolUse groups with
      # matcher == "WebSearch": any group with that matcher is dropped (so a
      # store path from an older build cannot linger) and the current hook is
      # appended, while the groups herdr and moshi-hook write are preserved.
      jq --argjson p '${permsJson}' --argjson h '${hooksJson}' \
        '.permissions = ((.permissions // {}) + $p.permissions)
         | .hooks.PreToolUse = ([((.hooks.PreToolUse // [])[] | select(.matcher != "WebSearch"))] + $h.hooks.PreToolUse)' \
        "$SETTINGS" > "$tmp"

      # Written via rename so a crash mid-write cannot leave truncated JSON,
      # which Claude Code treats as "no settings at all" — deny list included.
      chmod 0644 "$tmp"
      mv "$tmp" "$SETTINGS"
      trap - EXIT

      echo "claude permissions applied ($(jq '.permissions.deny | length' "$SETTINGS") deny, $(jq '.permissions.allow | length' "$SETTINGS") allow)"
    '';
  };
in {
  users.users.${user}.linger = true;

  systemd.user.services.claude-permissions = {
    description = "Apply Claude Code permission guardrails for ${user}";
    wantedBy = ["default.target"];

    # After both writers, so this is the last word on the file each boot. After=
    # on a non-existent unit is a no-op, so this stays valid if either module is
    # not imported.
    after = ["moshi-hook-setup.service" "herdr-setup.service"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${apply}/bin/claude-permissions-apply";
    };
  };
}
