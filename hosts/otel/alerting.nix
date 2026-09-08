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
            # warning, not critical: blackbox.nix now labels every probe target
            # with the `instance` of the node-exporter job for the host it lives
            # on, so when that host is entirely down, TargetDown (critical) fires
            # for the same instance and the inhibit_rule below swallows this one.
            # A ProbeFailed alert that still gets through therefore means the
            # host is up but the specific service on it is not -- real news, but
            # one severity level down from a whole host being gone.
            alert = "ProbeFailed";
            expr = "probe_success == 0";
            for = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.instance }} is failing its health probe ({{ $labels.probe_target }})";
              description = "The blackbox probe for {{ $labels.probe_target }} on {{ $labels.instance }} has failed for 5 minutes. Note this can fire while the host itself is perfectly up -- it checks that the service still does its job, not that a process is listening.";
            };
          }
        ];
      }
      {
        name = "certificates";
        rules = [
          {
            # On 2026-09-07 hofvarpnir.homelab.local served a cert that had been
            # expired for 3.3 days. Nothing here noticed: the metric below was
            # scraped the whole time with no rule attached to it, and the only
            # alert that ever fired was TargetDown -- i.e. after the expiry had
            # already broken the scrape. This rule is the "before" half.
            #
            # Caddy renews step-ca's 30-day certs at 2/3 life, with ~10 days
            # left. Firing at 7 means a renewal has already failed at least
            # once, while a week of slack remains. `for = 1h` because this value
            # slides down continuously rather than flipping -- there is no such
            # thing as a one-scrape blip worth waking up for.
            #
            # homelab-ca is excluded, not overlooked: step-ca gives its own TLS
            # leaf a 24h lifetime and rotates it continuously, so it sits
            # permanently below any multi-day threshold and would flap forever.
            #
            # LIMIT, and it is a big one: probe_ssl_earliest_cert_expiry only
            # exists for names blackbox.nix actually probes, and Caddy manages a
            # separate certificate per subject name. Every service there is
            # probed on exactly one of its two names, so ~51 of the fleet's ~72
            # step-ca subjects -- including the hofvarpnir.homelab.local that
            # caused this -- are still invisible to this rule. See the audit
            # note in blackbox.nix before trusting a green board.
            alert = "CertificateExpiringSoon";
            expr = "(probe_ssl_earliest_cert_expiry{instance!=\"homelab-ca\"} - time()) / 86400 < 7";
            for = "1h";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.probe_target }} certificate expires in {{ $value | printf \"%.1f\" }} days";
              description = "ACME renewal against ca.homelab.local has most likely wedged -- the backoff is in-process and does not recover on its own. Restart caddy on the serving host and allow ~2.5 minutes for renewal to finish before rechecking.";
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
      {
        name = "resource-usage";
        rules = [
          {
            # forgejo's qemu-ga sat in an unthrottled EAGAIN retry loop (~22k
            # failed write()s/sec against a virtio-serial channel the host had
            # stopped draining) from 2026-08-19 to 08-31, pinning most of one
            # of that VM's 2 vCPUs for twelve days. Nothing caught it: the
            # process never exits, so Restart=always does not help, and a
            # busy-loop looks perfectly healthy to systemd.
            #
            # iowait is excluded deliberately. These guests live on zfs_pool
            # (two HDDs, ~78 IOPS shared cluster-wide) and sit at 50-75%
            # iowait while doing almost no real I/O, which swamps any CPU
            # signal -- see todo/ssd-tier-for-vm-storage.md. What is left is
            # real work, normalized per core so the threshold means the same
            # thing on a 2 vCPU guest as on the hypervisor.
            #
            # Measured 2026-08-31: forgejo read 0.455 while spinning (0.513 at
            # the sample this expr was validated against) and 0.018 once
            # restarted. Idle guests sit at 0.02-0.08, so 0.35 clears both by
            # a wide margin.
            #
            # database and pve-gigabyte are excluded because they genuinely run
            # at this level around the clock (0.50 and 0.37). No threshold
            # separates them from a spin -- their 6h *minimum* does not drop
            # below 0.25 either, so min_over_time does not help. Without the
            # exclusion this rule fires on them permanently and gets tuned out,
            # which is the failure mode this whole file exists to prevent.
            # Revisit if either host is ever right-sized or investigated.
            alert = "SustainedHighCPU";
            expr = "sum by (instance) (rate(node_cpu_seconds_total{mode!~\"idle|iowait|steal\",instance!~\"homelab-database|pve-gigabyte\"}[15m])) / on(instance) count by (instance) (node_cpu_seconds_total{mode=\"idle\"}) > 0.35";
            # Long on purpose: this is a slow burn, not an outage. Nothing
            # breaks in the first hour, and 6h keeps nix builds on
            # `development` and the nightly backup window from paging.
            for = "6h";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.instance }} has burned {{ $value | printf \"%.2f\" }} CPU per core for 6 hours";
              description = "Sustained non-iowait CPU with no let-up, which usually means a process stuck in a syscall retry loop rather than doing real work. Confirm on the host with: ps -eo pid,%cpu,stat,comm --sort=-%cpu | head, then strace -c -p <pid> -- a spin shows tens of thousands of calls per second, nearly all erroring. Restarting the offending unit clears it.";
            };
          }
        ];
      }
    ];
  };
in {
  services.prometheus = {
    ruleFiles = [alertRules];

    # Alertmanager has to be *scraped*, not just pointed at. `alertmanagers`
    # below is where prometheus SENDS alerts; it does not collect anything back.
    # Without this job alertmanager_notifications_failed_total has no series at
    # all, and the AlertmanagerNotificationsFailing rule silently evaluates
    # against nothing forever -- a broken watchdog that reports healthy, which is
    # the same class of bug as the one this whole change exists to catch.
    scrapeConfigs = [
      {
        job_name = "alertmanager";
        static_configs = [
          {
            targets = ["127.0.0.1:${toString config.services.prometheus.alertmanager.port}"];
            labels.instance = "homelab-otel";
          }
        ];
      }
    ];

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
        # a service on it. Only the first is news, so this suppresses the rest.
        #
        # This depends on `instance` meaning the same thing in both job
        # families. It didn't used to: blackbox labelled `instance` with the
        # probed URL while node jobs labelled it with a host name, so `equal`
        # here matched nothing and every host outage paged twice. Fixed by
        # having blackbox.nix set each probe target's `instance` explicitly to
        # the node-exporter `instance` of the host it lives on (the raw URL is
        # preserved separately as `probe_target`, since several probes now
        # intentionally share one instance). ProbeFailed is also `warning` for
        # the same reason -- inhibit_rules only ever suppress a target severity
        # given a firing source severity, and TargetDown/ProbeFailed used to be
        # the same severity, so this rule never actually fired either.
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
