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
  probeTargets = {
    http_2xx = [
      # The lesson above, encoded. Of the app's three health endpoints this is the
      # comprehensive one (database + yt-dlp, 503 when unhealthy) and the one its
      # OpenAPI schema recommends for monitoring. Do NOT switch this to
      # /api/health/live: that probe checks no dependencies by design, so it would
      # have stayed green through the whole outage described above.
      "https://hofvarpnir.homelab.internal/api/health"
      "https://axon.homelab.internal/health"
      "https://hermes.homelab.internal/health"
      "https://cache.homelab.internal/homelab/nix-cache-info"
      # Stays on .local: forgejo's caddy has no usable cert for its .internal name
      # and aborts the TLS handshake for that SNI (probe_http_ssl 0, no HTTP
      # response at all, 6ms failure) even though DNS resolves and 443 is open.
      # The vhost lists both names, so this is an ACME/cert gap on that host, not
      # a config error -- and it predates this file. Fix the cert, then switch.
      "https://forgejo.homelab.local"
      "https://ci.homelab.internal"
      "https://harbor.homelab.internal"
      "https://searxng.homelab.internal"
      "https://romm.homelab.internal"
      "https://containers.homelab.internal"
      "https://containers.homelab.internal/uptime-forge"
      # The one name deliberately left on .local: step-ca is not behind Caddy (it
      # serves :8443 itself), so unlike every entry above there is no vhost
      # listing both names -- whether its cert carries a ca.homelab.internal SAN
      # is a step-ca config question, not a DNS one. Switch it only after
      # confirming that cert, or the probe fails on a name change alone.
      "https://ca.homelab.local:8443/health"
      # Grafana runs on this host. Probed over loopback on purpose: going out via
      # otel.homelab.local would make a Grafana alert also depend on unbound,
      # Caddy and step-ca, so a DNS blip would read as "Grafana is down".
      "http://localhost:3000/api/health"
    ];
    tcp_connect = [
      # The router redirects :80 to a self-signed HTTPS vhost. An HTTP prober
      # would mark that down for certificate reasons that say nothing about
      # whether the router is alive, so check the honest thing: does it accept a
      # TCP connection.
      "192.168.2.1:80"
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
    static_configs = [{inherit targets;}];
    relabel_configs = [
      {
        source_labels = ["__address__"];
        target_label = "__param_target";
      }
      {
        source_labels = ["__param_target"];
        target_label = "instance";
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
