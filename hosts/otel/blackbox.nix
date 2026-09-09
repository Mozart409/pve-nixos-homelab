{
  config,
  lib,
  pkgs,
  ...
}: let
  # Blackbox probes a service from the outside, the way a user reaches it. That
  # is the gap that let hofvarpnir sit dead for 20h43m on 2026-08-13: the process
  # was alive, `up{job="hofvarpnir"}` was 1 the whole time, and its HTTP root kept
  # returning 200 -- while the download supervisor actor had panicked and every
  # queued download silently stopped. Only the health endpoints knew.
  #
  # So the rule for this list: probe the endpoint that proves the service DOES its
  # job, not the one that proves a process is listening. The retired `cache`
  # entry was the same idea -- its /health was answered by Caddy itself and
  # stayed green when atticd was dead, so the probe used nix-cache-info instead.
  #
  # These URLs are deliberately the ones already proven good by the dashboard's
  # health_checks list, plus hofvarpnir's readiness path. Do not add a target
  # here without curling it first: a probe pointed at a 404 is an alert that
  # fires forever and trains you to ignore the channel.
  # Each target now carries the `instance` value of the node-exporter job for
  # the host it lives on (see the matching `labels.instance` in
  # ./configuration.nix), instead of prometheus deriving `instance` from the
  # probed URL. That is what lets alerting.nix's inhibit_rules actually
  # collapse a ProbeFailed alert into the TargetDown alert for the same host --
  # see the comment there for why they used to be two unrelated label spaces.
  #
  # CERT COVERAGE (audited 2026-09-07). Every https entry below also yields
  # probe_ssl_earliest_cert_expiry for free, which alerting.nix's
  # CertificateExpiringSoon now consumes -- but only for the exact SNI probed,
  # and Caddy manages a separate certificate per subject name. Counting every
  # vhost across hosts/ and modules/ (excluding .ts.net, which uses Tailscale
  # certs, and the http:// redirect vhosts): 72 step-ca subjects exist, 21 are
  # probed, 51 are not. Every service is probed on exactly ONE of its two
  # names, never both.
  #
  # That is not a cosmetic gap. hofvarpnir.homelab.internal is probed and was
  # green throughout 2026-09-04..07 while hofvarpnir.homelab.local -- same
  # vhost, same host, different cert -- sat expired for 3.3 days.
  #
  # Adding 51 http_2xx targets would violate the rule above -- many of these
  # names have no known-good 2xx path. Hence the `tls_cert` module below: a tcp
  # prober with tls, which completes a handshake and exports
  # probe_ssl_earliest_cert_expiry while speaking no HTTP at all. That
  # distinction is load-bearing, not theoretical: loki (404), tempo (502) and
  # pgadmin.homelab.internal (backend hangs past 8s) every one of them verified
  # clean at the TLS layer on 2026-09-07 while being useless as http_2xx
  # targets.
  #
  # Every name in certSubjects was curl-verified ssl_verify_result=0 on
  # 2026-09-07 before being added, per the rule above. Verified BROKEN that day
  # and therefore deliberately absent -- add each back when it is fixed, that is
  # the whole point of having found them:
  #   pgadmin.homelab.local        verify=10, CERT EXPIRED (host: database)
  #   unifi.homelab.internal       verify=1
  #   *-mcp.homelab.internal (11)  verify=1 -- the same .internal gap already
  #                                described on the mcp_probe list below, whose
  #                                cause is NOT that the vhost omits the name
  #                                (mcp_vm/configuration.nix:27 lists both)
  #
  # Hosts deliberately absent: fleet, harbor, hermes and woodpecker (VMs shut
  # off, 2026-08-31..09-07), zeroclaw and wotan (down since 2026-08-15, see the
  # removed scrape jobs in ./configuration.nix), k3s-cntrl-1 (DNS record gone).
  #
  # Keyed by the node-exporter `instance` of the host serving the vhost, so a
  # whole-host outage still collapses into one TargetDown rather than N
  # ProbeFailed -- the same dedup contract as the lists below.
  certSubjects = {
    homelab-containers = [
      "containers.homelab.local"
      "containers.homelab.internal"
      "axon.homelab.local"
      "axon.homelab.internal"
      "albyhub.homelab.local"
      "albyhub.homelab.internal"
      "dashboard.homelab.local"
      "dashboard.homelab.internal"
      "romm.homelab.local"
      "romm.homelab.internal"
      "searxng.homelab.local"
      "searxng.homelab.internal"
    ];
    homelab-database = [
      "database.homelab.local"
      "database.homelab.internal"
      "pgadmin.homelab.internal"
    ];
    homelab-dns = [
      "dns.homelab.local"
      "dns.homelab.internal"
    ];
    homelab-forgejo = [
      "forgejo.homelab.local"
      "forgejo.homelab.internal"
    ];
    homelab-jellyfin = [
      "jellyfin.homelab.local"
      "jellyfin.homelab.internal"
      "hofvarpnir.homelab.local"
      "hofvarpnir.homelab.internal"
    ];
    homelab-otel = [
      "otel.homelab.local"
      "otel.homelab.internal"
      "alertmanager.homelab.local"
      "alertmanager.homelab.internal"
      "loki.homelab.local"
      "loki.homelab.internal"
      "tempo.homelab.local"
      "tempo.homelab.internal"
      "prometheus.homelab.local"
      "prometheus.homelab.internal"
    ];
    homelab-unifi = [
      "unifi.homelab.local"
    ];
    homelab-mcp = [
      "mcp.homelab.local"
      "pbs-mcp.homelab.local"
      "pg-uptime-mcp.homelab.local"
      "pg-appdb-mcp.homelab.local"
      "pg-terraform-mcp.homelab.local"
      "pg-forgejo-mcp.homelab.local"
      "pg-romm-mcp.homelab.local"
      "pg-hofvarpnir-mcp.homelab.local"
      "prom-mcp.homelab.local"
      "loki-mcp.homelab.local"
      "wp-mcp.homelab.local"
    ];
  };

  certTargets = lib.concatLists (lib.mapAttrsToList (instance: names:
    map (n: {
      url = "${n}:443";
      inherit instance;
    })
    names)
  certSubjects);

  probeTargets = {
    http_2xx = [
      # The lesson above, encoded. Of the app's three health endpoints this is the
      # comprehensive one (database + yt-dlp, 503 when unhealthy) and the one its
      # OpenAPI schema recommends for monitoring. Do NOT switch this to
      # /api/health/live: that probe checks no dependencies by design, so it would
      # have stayed green through the whole outage described above.
      {
        url = "https://hofvarpnir.homelab.internal/api/health";
        instance = "hofvarpnir";
      }
      {
        url = "https://axon.homelab.internal/health";
        instance = "homelab-containers";
      }
      {
        url = "https://hermes.homelab.internal/health";
        instance = "homelab-hermes";
      }
      # Stays on .local, but no longer for the original reason. This entry used
      # to carry a note that forgejo's caddy had no usable cert for its
      # .internal name and aborted the handshake for that SNI, ending "fix the
      # cert, then switch". That cert has since been fixed:
      # `curl https://forgejo.homelab.internal` returned 200 with
      # ssl_verify_result=0 on 2026-09-07.
      #
      # Not switching anyway. Changing this URL rewrites the `probe_target`
      # label and orphans the existing series for no gain, and since 2026-09-07
      # BOTH names are covered for cert expiry by the tls_cert job above, which
      # is what the switch was originally meant to achieve.
      {
        url = "https://forgejo.homelab.local";
        instance = "homelab-forgejo";
      }
      {
        url = "https://ci.homelab.internal";
        instance = "homelab-woodpecker";
      }
      {
        url = "https://harbor.homelab.internal";
        instance = "homelab-harbor";
      }
      {
        url = "https://searxng.homelab.internal";
        instance = "homelab-containers";
      }
      {
        url = "https://romm.homelab.internal";
        instance = "homelab-containers";
      }
      {
        url = "https://containers.homelab.internal";
        instance = "homelab-containers";
      }
      {
        url = "https://containers.homelab.internal/uptime-forge";
        instance = "homelab-containers";
      }
      # The one name deliberately left on .local: step-ca is not behind Caddy (it
      # serves :8443 itself), so unlike every entry above there is no vhost
      # listing both names -- whether its cert carries a ca.homelab.internal SAN
      # is a step-ca config question, not a DNS one. Switch it only after
      # confirming that cert, or the probe fails on a name change alone.
      {
        url = "https://ca.homelab.local:8443/health";
        instance = "homelab-ca";
      }
      # Grafana runs on this host. Probed over loopback on purpose: going out via
      # otel.homelab.local would make a Grafana alert also depend on unbound,
      # Caddy and step-ca, so a DNS blip would read as "Grafana is down".
      {
        url = "http://localhost:3000/api/health";
        instance = "homelab-otel";
      }
    ];

    # MCP streamable-HTTP endpoints on mcp_vm (hosts/mcp_vm/configuration.nix).
    # A bare GET here -- no session id, no `Accept: application/json,
    # text/event-stream` -- is correctly rejected with 406 by a spec-compliant
    # server; that is the healthy response, not a failure (see AGENTS.md's
    # curl guidance: 200/302/406 all mean "up", only 000 means down). Hence
    # the separate `mcp_probe` module below instead of http_2xx.
    #
    # Every one of these shares instance = "homelab-mcp": mcp_vm hosts 11
    # independent MCP server processes behind one Caddy, and none of them had
    # any health check at all before this -- TargetDown only proves the host
    # and node-exporter are up, not that any individual MCP backend behind it
    # still answers axon-gateway (see hosts/containers/axon-gateway/default.nix
    # for the backend list this mirrors).
    #
    # Stays on .homelab.local: an .internal SNI here still fails TLS
    # verification (curl ssl_verify_result=1 for prom-mcp and mcp on
    # 2026-09-07), so the symptom this comment always described is real.
    #
    # Its stated CAUSE was wrong, though, and the wrong cause sends you to the
    # wrong file: the vhosts do NOT "only register the .local names". They list
    # both -- hosts/mcp_vm/configuration.nix:27 builds every vhost key as
    # "${base}.homelab.local ${base}.homelab.internal". So this is a cert that
    # was never successfully obtained or has gone bad for the .internal subject,
    # not a name missing from the Caddy config. Caddy issues one cert per
    # subject name rather than one multi-SAN cert per vhost, which is what makes
    # that possible -- proven by the per-identifier ACME orders in caddy's
    # journal on homelab-jellyfin, 2026-09-07.
    #
    # Consequence: all 11 .internal names are excluded from the tls_cert job
    # above. Fix them and add them there.
    mcp_probe = [
      {
        url = "https://mcp.homelab.local/mcp"; # Home Assistant (hamcp)
        instance = "homelab-mcp";
      }
      {
        url = "https://pbs-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-uptime-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-appdb-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-terraform-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-forgejo-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-romm-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://pg-hofvarpnir-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://prom-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://loki-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
      {
        url = "https://wp-mcp.homelab.local/mcp";
        instance = "homelab-mcp";
      }
    ];

    # Generated from certSubjects above -- 49 subjects across 9 live hosts.
    tls_cert = certTargets;

    tcp_connect = [
      # The router redirects :80 to a self-signed HTTPS vhost. An HTTP prober
      # would mark that down for certificate reasons that say nothing about
      # whether the router is alive, so check the honest thing: does it accept a
      # TCP connection. No matching node-exporter job exists for it, so it never
      # gets deduped by an instance-matched TargetDown -- there is nothing to
      # dedupe against.
      {
        url = "192.168.2.1:80";
        instance = "router";
      }
    ];
  };

  blackboxConfig = (pkgs.formats.yaml {}).generate "blackbox.yml" {
    modules = {
      http_2xx = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          # Redirects are followed, so a service that bounces / -> /login still
          # passes as long as the final response is 2xx.
          follow_redirects = true;
          valid_http_versions = ["HTTP/1.1" "HTTP/2.0"];
          # Blackbox defaults to trying IPv6 first and falling back. Every target
          # here is v4-only, so pinning this skips a guaranteed-failed connect on
          # every probe of every target.
          preferred_ip_protocol = "ip4";
        };
      };

      # See the mcp_probe target comment above for why 406 counts as healthy.
      mcp_probe = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [200 406];
          follow_redirects = true;
          valid_http_versions = ["HTTP/1.1" "HTTP/2.0"];
          preferred_ip_protocol = "ip4";
        };
      };

      tcp_connect = {
        prober = "tcp";
        timeout = "5s";
        tcp.preferred_ip_protocol = "ip4";
      };

      # Certificate surveillance, not service health. The tcp prober derives SNI
      # from the target hostname, so `name:443` handshakes against exactly that
      # subject's certificate -- which is what makes per-subject coverage
      # possible at all, since Caddy issues one cert per name rather than one
      # multi-SAN cert per vhost (proven by the per-identifier renewal orders in
      # caddy's journal on homelab-jellyfin, 2026-09-07).
      #
      # probe_success here means "the handshake completed against a cert this
      # host trusts", so an expired or untrusted cert fails it. Combined with
      # probe_ssl_earliest_cert_expiry that gives both halves: ProbeFailed once
      # a cert is already bad, CertificateExpiringSoon a week before it is.
      tls_cert = {
        prober = "tcp";
        timeout = "10s";
        tcp = {
          tls = true;
          preferred_ip_protocol = "ip4";
        };
      };
    };
  };

  # Standard blackbox indirection: the scrape goes to the *exporter*, with the
  # real target handed over as ?target=. Without these relabels every series
  # would carry the exporter's own address as `instance` and all targets would
  # collapse into one indistinguishable series.
  mkProbeJob = module: targets: {
    job_name = "blackbox-${module}";
    metrics_path = "/probe";
    params.module = [module];
    # One static_configs entry per target so each carries its own
    # `labels.instance` -- that value now comes from the target's own
    # `instance` field above rather than being derived from the URL below.
    static_configs =
      map (t: {
        targets = [t.url];
        labels.instance = t.instance;
      })
      targets;
    relabel_configs = [
      {
        source_labels = ["__address__"];
        target_label = "__param_target";
      }
      # Keeps the actual probed URL visible as its own label. Several targets
      # above intentionally share one `instance` (e.g. every containers.* /
      # searxng / romm probe is instance = "homelab-containers"), so this is
      # the only thing left in an alert that says which URL failed -- see its
      # use in alerting.nix's ProbeFailed annotations.
      {
        source_labels = ["__param_target"];
        target_label = "probe_target";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}";
      }
    ];
  };
in {
  services.prometheus.exporters.blackbox = {
    enable = true;
    # Only prometheus on this host ever talks to it, so it never needs to be
    # reachable off-box and no firewall port is opened for it.
    listenAddress = "127.0.0.1";
    configFile = blackboxConfig;
  };

  # Merges with the scrapeConfigs list in ./configuration.nix.
  services.prometheus.scrapeConfigs = lib.mapAttrsToList mkProbeJob probeTargets;
}
