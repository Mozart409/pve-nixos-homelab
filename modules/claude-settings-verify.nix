{
  pkgs,
  config,
  ...
}: let
  user = "amadeus";
  home = "/home/amadeus";

  # Guardrail drift detection for ~/.claude/settings.json.
  #
  # Why: modules/herdr.nix and modules/moshi-hook-user.nix both write that file
  # at boot (herdr-setup.service, moshi-hook-setup.service). Each does a targeted
  # edit of its own hook entries, which is why they coexist — but a wholesale
  # rewrite by either would silently drop `permissions.deny`, and Claude Code
  # then fails OPEN: no error, no log, just an agent that can suddenly run
  # nixos-rebuild. herdr.nix already notes "both hook sets must be re-verified
  # after deploy"; this is that verification, automated.
  #
  # Deliberately checks for the presence of required rules rather than hashing
  # the file, so ordinary edits do not produce false alarms.
  verify = pkgs.writeShellApplication {
    name = "claude-settings-verify";
    runtimeInputs = [pkgs.jq pkgs.curl pkgs.hostname];
    text = ''
      SETTINGS="''${CLAUDE_SETTINGS:-${home}/.claude/settings.json}"
      problems=()

      if [ ! -f "$SETTINGS" ]; then
        problems+=("settings.json is missing entirely")
      elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        # Invalid JSON silently disables every setting in the file, deny included.
        problems+=("settings.json is not valid JSON — all its settings are disabled")
      else
        required_deny=(
          "Read(//home/amadeus/.ssh/**)"
          "Read(//home/amadeus/.claude/.credentials.json)"
          "Bash(rm -rf /*)"
          "Bash(sudo rm *)"
          "Bash(nixos-rebuild*)"
          "Bash(sudo nixos-rebuild*)"
          "Bash(nh os*)"
          "Bash(sudo nh*)"
          "Bash(home-manager switch*)"
          "Bash(git push --force*)"
          "Bash(gh pr merge*)"
        )
        for rule in "''${required_deny[@]}"; do
          if ! jq -e --arg r "$rule" '.permissions.deny // [] | index($r)' "$SETTINGS" >/dev/null 2>&1; then
            problems+=("deny rule missing: $rule")
          fi
        done

        mode=$(jq -r '.permissions.defaultMode // "unset"' "$SETTINGS")
        [ "$mode" = "dontAsk" ] || problems+=("defaultMode is '$mode', expected 'dontAsk'")

        # Confirms neither integration's setup service ate the other's entries.
        grep -q "moshi-hook" "$SETTINGS" || problems+=("moshi-hook hook entries gone")
        grep -q "herdr-agent-state" "$SETTINGS" || problems+=("herdr hook entries gone")
      fi

      if [ ''${#problems[@]} -eq 0 ]; then
        echo "claude settings OK on $(hostname)"
        exit 0
      fi

      body="Claude guardrail drift on $(hostname):"
      for p in "''${problems[@]}"; do
        body="$body"$'\n'"- $p"
      done
      echo "$body" >&2

      # Notify via the axon MCP gateway rather than Home Assistant directly:
      # homeassistant-token.age is not keyed to this host, but axon-gateway-env.age
      # is. The gateway accepts a stateless tools/call POST — no session handshake.
      # These are notify *entities*, so it is notify.send_message + entity_id,
      # not the legacy notify.<service> form.
      if [ -n "''${AXON_GATEWAY_TOKEN:-}" ]; then
        payload=$(jq -nc --arg msg "$body" '{
          jsonrpc: "2.0", id: 1, method: "tools/call",
          params: {
            name: "hamcp_call_service",
            arguments: {
              domain: "notify",
              service: "send_message",
              entity_id: "notify.iphone_von_amadeus",
              service_data: {message: $msg}
            }
          }
        }')
        curl -sS --max-time 20 -X POST https://axon.homelab.local/mcp \
          -H "Authorization: Bearer $AXON_GATEWAY_TOKEN" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json, text/event-stream" \
          -d "$payload" >/dev/null || echo "notify failed" >&2
      else
        echo "AXON_GATEWAY_TOKEN unset — cannot notify" >&2
      fi

      exit 1
    '';
  };
in {
  systemd.user.services.claude-settings-verify = {
    description = "Verify ~/.claude/settings.json guardrails for ${user}";
    wantedBy = ["default.target"];

    # The whole point: run *after* the two services that rewrite settings.json,
    # so a clobber is caught on the same boot that causes it rather than on the
    # next timer tick. After= on a non-existent unit is a no-op, so this stays
    # valid if either module is not imported.
    after = ["herdr-setup.service" "moshi-hook-setup.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${verify}/bin/claude-settings-verify";
      EnvironmentFile = config.age.secrets.axon-gateway-env.path;
      # Drift is reported by notification, not by a failed unit that nothing reads.
      SuccessExitStatus = "0 1";
    };
  };

  # Backstop for drift between boots — e.g. a manual `herdr integration install`
  # or `moshi-hook install`, which rewrite settings.json outside activation.
  systemd.user.timers.claude-settings-verify = {
    description = "Daily Claude settings guardrail check for ${user}";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };
}
