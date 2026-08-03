{pkgs, ...}: let
  user = "amadeus";
  home = "/home/amadeus";

  perms = import ./claude-permissions-data.nix;

  # Only the permissions block, as JSON. Merged into settings.json rather than
  # written as the whole file: modules/herdr.nix and modules/moshi-hook-user.nix
  # own the `hooks` key there, and Claude Code itself writes UI state into it.
  permsJson = builtins.toJSON {
    permissions = {
      inherit (perms) allow deny defaultMode;
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
      jq --argjson p '${permsJson}' \
        '.permissions = ((.permissions // {}) + $p.permissions)' \
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
