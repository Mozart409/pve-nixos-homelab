{harness}:
harness.mkHostTest {
  name = "otel";
  hostPath = ../../hosts/otel/configuration.nix;
  memorySize = 2048; # prometheus + grafana + loki + otel-collector concurrently
  extraModules = [
    harness.clearStaticNetworking
    harness.useTestAgeIdentity
    (harness.fixtureSecret "grafana-secret-key" ../fixtures/secrets/grafana-secret-key.age)
    (harness.fixtureSecret "grafana-oidc-secret" ../fixtures/secrets/grafana-oidc-secret.age)
  ];
  testScript = ''
    machine.wait_for_unit("multi-user.target")

    machine.wait_for_unit("prometheus.service")
    machine.wait_for_open_port(9090)
    machine.succeed("curl -sf http://127.0.0.1:9090/-/ready")

    machine.wait_for_unit("loki.service")
    machine.wait_for_open_port(3100)
    machine.succeed("curl -sf http://127.0.0.1:3100/ready")

    # Requires grafana-secret-key + grafana-oidc-secret to have decrypted for
    # real (fixtured above) -- otherwise grafana fails resolving
    # $__file{...} in its settings and never reaches "active".
    machine.wait_for_unit("grafana.service")
    machine.wait_for_open_port(3000)
    machine.succeed("curl -sf http://127.0.0.1:3000/api/health")

    machine.wait_for_unit("otel-collector.service")
    machine.wait_for_open_port(4317)
    machine.wait_for_open_port(4318)
    # Empty POST to the OTLP/HTTP traces endpoint: a real otel-collector
    # answers 400/415 (bad protobuf), proving the HTTP server itself is
    # alive and responding, not just that the port is open.
    machine.succeed(
        "code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4318/v1/traces); "
        "[ \"$code\" = 400 ] || [ \"$code\" = 415 ]"
    )

    machine.wait_for_unit("alertmanager.service")
    machine.wait_for_open_port(9093)

    # NOT asserted on, intentionally: axon-gateway-env (the
    # alertmanager-axon-bridge's EnvironmentFile) and woodpecker-metrics-token
    # (one scrape job's credentials_file) are not fixtured -- their failures
    # are peripheral and don't gate prometheus/grafana/loki/otel-collector
    # availability.
  '';
}
