#!/usr/bin/env bash
# Regenerates the test-only age identity and the fixture secrets consumed by
# tests/hosts/otel.nix. Run from this directory (tests/fixtures/). Safe to
# re-run: it overwrites the same test-only files, never touches secrets/.
set -euo pipefail
cd "$(dirname "$0")"

age-keygen -o test-age-identity.txt
pubkey=$(age-keygen -y test-age-identity.txt)

mkdir -p secrets
echo -n "test-fixture-grafana-secret-key-not-real" \
  | age -r "$pubkey" -o secrets/grafana-secret-key.age
echo -n "test-fixture-grafana-oidc-secret-not-real" \
  | age -r "$pubkey" -o secrets/grafana-oidc-secret.age

echo "Regenerated. Public key: $pubkey"
echo "(no action needed elsewhere -- tests/lib.nix and tests/hosts/otel.nix reference these paths directly)"
