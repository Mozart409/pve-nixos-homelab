# Test fixtures for nixosTest integration tests

`test-age-identity.txt` is a disposable age keypair used ONLY inside
nixosTest VMs (see `../lib.nix`'s `useTestAgeIdentity`). It has no
relationship to any real host key or entry in `secrets/secrets.nix`, and is
committed deliberately -- it exists purely so agenix's real decrypt pipeline
can succeed for real inside a test VM for the small number of secrets whose
consuming PRIMARY service a test asserts on (currently: otel's
`grafana-secret-key` and `grafana-oidc-secret`).

`secrets/*.age` are dummy values encrypted to this identity's public key --
NOT copies of, or derived from, the real production secrets.

To regenerate (only needed if the identity is rotated, or a new host's
tested primary service needs another secret fixtured): `./regenerate.sh`.
