#!/usr/bin/env bash
# colmena-drift.sh — report which hosts are behind the current checkout.
#
# A host is "up to date" iff the system closure it is currently running
# (readlink /run/current-system) matches the toplevel store path that the
# current flake builds for it. Colmena has no built-in drift command, so we
# build each host locally and compare against the live system path.
#
# We build `colmenaHive.nodes.<h>`, NOT `nixosConfigurations.<h>`: the latter is
# produced by mkHost, which omits the home-manager/nixvim layer (see flake.nix),
# so its toplevel NEVER equals what `colmena apply` deployed and every host would
# report a false DRIFT.
#
# Output is one line per host: OK / DRIFT / UNREACHABLE / BUILD-FAIL.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# colmenaHive node names that also exist under nixosConfigurations.
hosts=(
  database otel dns unifi containers mcp ca fleet harbor cache
  forgejo buildbot-master buildbot-worker-1 hermes
)

# Allow overriding the host list: ./tools/colmena-drift.sh dns cache
if [[ $# -gt 0 ]]; then
  hosts=("$@")
fi

drift=0
for h in "${hosts[@]}"; do
  want=$(nix build --no-link --print-out-paths \
           ".#colmenaHive.nodes.$h.config.system.build.toplevel" 2>/dev/null) || {
    printf 'BUILD-FAIL  %s\n' "$h"; drift=1; continue; }

  # colmena writes per-node command output to STDERR (prefixed "<node> | "), so
  # this must capture 2>&1 — discarding stderr yields an empty result and every
  # host reports UNREACHABLE. Match only nixos-system paths so a store path
  # appearing inside an error message can't be mistaken for the live system.
  have=$(colmena exec --on "$h" -- readlink /run/current-system 2>&1 \
           | grep -oE '/nix/store/[^[:space:]]*nixos-system[^[:space:]]*' | tail -1) || true
  if [[ -z "$have" ]]; then
    printf 'UNREACHABLE %s\n' "$h"; drift=1; continue
  fi

  if [[ "$want" == "$have" ]]; then
    printf 'OK          %s\n' "$h"
  else
    printf 'DRIFT       %s  (running %s)\n' "$h" "${have##*/}"
    drift=1
  fi
done

exit "$drift"
