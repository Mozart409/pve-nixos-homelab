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
  # job, not the one that proves a process is listening. The `cache` entry below
  # (and the comment on it in hosts/containers/homelab-dashboard/default.nix) is
  # the same idea -- /health there is answered by Caddy itself and stays green
  # when atticd is dead.
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
      {
        url = "https://cache.homelab.internal/homelab/nix-cache-info";
        instance = "homelab-cache";
      }
      # Stays on .local: forgejo's caddy has no usable cert for its .internal name
      # and aborts the TLS handshake for that SNI (probe_http_ssl 0, no HTTP
      # response at all, 6ms failure) even though DNS resolves and 443 is open.
      # The vhost lists both names, so this is an ACME/cert gap on that host, not
      # a config error -- and it predates this file. Fix the cert, then switch.
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
    # Stays on .homelab.local, not .internal: mcp_vm's Caddy vhosts only
    # register the .local names with step-ca (see virtualHosts in
    # hosts/mcp_vm/configuration.nix), so an .internal SNI would abort the TLS
    # handshake -- the same gap documented on the forgejo entry above.
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
