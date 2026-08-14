{
  config,
  lib,
  pkgs,
  ...
}: let
  # Prometheus scraped ~17 hosts for months into a system where no alert could
  # fire: no rules, no alertmanager, and Grafana provisioned with datasources
  # only. Four targets were down and unnoticed when this was written. Everything
  # in this file exists to close that.
  #
  # The delivery chain is:
  #   prometheus -> alertmanager -> bridge (127.0.0.1:9099) -> axon gateway
  #                                                         -> HA notify entity
  bridgePort = 9099;

  alertRules = (pkgs.formats.yaml {}).generate "homelab-alerts.yml" {
    groups = [
      {
        name = "availability";
        rules = [
          {
            alert = "TargetDown";
            expr = "up == 0";
            # Long enough that a colmena apply, a service restart or a reboot
            # does not page; short enough to catch a real outage the same hour.
            for = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.instance }} is down ({{ $labels.job }})";
              description = "Prometheus has failed to scrape job {{ $labels.job }} on {{ $labels.instance }} for 5 minutes.";
            };
          }
          {
            alert = "ProbeFailed";
            expr = "probe_success == 0";
            for = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.instance }} is failing its health probe";
              description = "The blackbox probe for {{ $labels.instance }} has failed for 5 minutes. Note this can fire while the host itself is perfectly up -- it checks that the service still does its job, not that a process is listening.";
            };
          }
        ];
      }
      {
        name = "monitoring-self";
        rules = [
          {
            # Who watches the watcher. This one is honest about its own limit:
            # if notification delivery is broken then this alert cannot be
            # delivered either. It exists so the failure is visible in the
            # Alertmanager UI and in Grafana rather than nowhere at all.
            alert = "AlertmanagerNotificationsFailing";
            expr = "rate(alertmanager_notifications_failed_total[15m]) > 0";
            for = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Alertmanager cannot deliver notifications";
              description = "Deliveries to the axon bridge are failing, so alerts are firing into a void. Check: systemctl status alertmanager-axon-bridge, and whether axon.homelab.local is reachable.";
            };
          }
        ];
      }
    ];
  };
in {
  services.prometheus = {
    ruleFiles = [alertRules];

    alertmanagers = [
      {
        static_configs = [{targets = ["127.0.0.1:${toString config.services.prometheus.alertmanager.port}"];}];
      }
    ];

    alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      webExternalUrl = "https://alertmanager.homelab.local";

      # Single node. Without this alertmanager still binds its gossip listener on
      # 9094 for a cluster that will never have a second member.
      extraFlags = ["--cluster.listen-address="];

      configuration = {
        route = {
          receiver = "axon-ha";
          # Group by alert *kind*, so a rebooting host that trips TargetDown and
          # several ProbeFailed at once arrives as two pushes rather than eight.
          group_by = ["alertname" "severity"];
          group_wait = "1m";
          group_interval = "5m";
          # Re-nag every 6h while something is still broken. The hofvarpnir
          # outage went 20h unnoticed; a single push that arrives while you are
          # asleep is not much better than none.
          repeat_interval = "6h";
        };

        receivers = [
          {
            name = "axon-ha";
            webhook_configs = [
              {
                url = "http://127.0.0.1:${toString bridgePort}/alert";
                send_resolved = true;
              }
            ];
          }
        ];

        # A host that is entirely down will trip TargetDown *and* every probe of
        # a service on it. Only the first is news.
        #
        # Caveat worth knowing: `equal` matches on identical label values, and
        # blackbox labels `instance` with the probed URL while node jobs label it
        # with a host name. So this only suppresses same-instance duplicates, not
        # "host down therefore its services are down" -- that would need a shared
        # label the two job families do not currently have.
        inhibit_rules = [
          {
            source_matchers = ["severity = critical"];
            target_matchers = ["severity = warning"];
            equal = ["instance"];
          }
        ];
      };
    };
  };

  # Translates Alertmanager's webhook schema into the axon gateway's MCP
  # JSON-RPC call. See the module docstring in the script for why delivery goes
  # through the gateway instead of straight to Home Assistant.
  systemd.services.alertmanager-axon-bridge = {
    description = "Bridge Alertmanager webhooks to Home Assistant via the axon MCP gateway";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];

    environment.BRIDGE_PORT = toString bridgePort;

    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./alertmanager-axon-bridge.py}";
      # systemd reads this as root before dropping to the DynamicUser, so the
      # secret stays 0400 root-owned (same pattern as open-webui's env file).
      EnvironmentFile = config.age.secrets.axon-gateway-env.path;
      Restart = "on-failure";
      RestartSec = "10s";

      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      MemoryMax = "128M";
    };
  };

  # NOTE: otel must be a recipient of this secret. It currently is not -- only
  # the containers and development hosts consume it. Add otel's host key to the
  # "axon-gateway-env.age" entry in secrets/secrets.nix and run `just reencrypt`,
  # or activation fails with "no identity matched any of the recipients".
  age.secrets.axon-gateway-env = {
    file = ../../secrets/axon-gateway-env.age;
    mode = "0400";
  };

  # Alertmanager binds loopback only; this vhost is the way in, and the reason
  # to want one is silences -- muting a known-broken host before it re-nags at
  # the 6h repeat_interval.
  services.caddy.virtualHosts."alertmanager.homelab.local alertmanager.homelab.internal" = {
    extraConfig = ''
      tls {
        ca https://ca.homelab.local:8443/acme/acme/directory
      }

      reverse_proxy localhost:${toString config.services.prometheus.alertmanager.port}
    '';
  };
}
