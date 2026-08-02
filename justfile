set dotenv-load
set unstable

default:
    just --choose

fmt:
  alejandra .

clear:
  clear

shell:
  nix develop . --command zsh

check: clear
  nix flake check --all-systems

# NixOS configuration commands
nixos-check:
  @echo "Checking all NixOS configurations..."
  nix flake check

nixos-test host:
  @echo "Dry building {{host}} configuration..."
  nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --dry-run

# DESTRUCTIVE: reinstalls the OS from scratch via nixos-anywhere (disko wipes ALL
# disks) — only for turning a bare VM into minimal NixOS. Never run against an
# already-provisioned host; for config changes use colmena-apply-host instead.
deploy-minimal ip:
  @echo "Deploying minimal to {{ip}}..."
  nixos-anywhere --flake .#minimal amadeus@{{ip}}

# DESTRUCTIVE: reinstalls the OS from scratch via nixos-anywhere (disko wipes ALL
# disks). For a config change to an already-installed host use colmena-apply-host.
# Guarded: type the host name to proceed, or set CONFIRM=<host> for scripted runs.
deploy host ip:
  #!/usr/bin/env bash
  set -euo pipefail
  echo ""
  echo "⚠️  DESTRUCTIVE: 'just deploy' runs nixos-anywhere and REINSTALLS the OS on"
  echo "   {{host}} ({{ip}}) — disko reformats ALL disks. Everything on the target is"
  echo "   destroyed: /var/lib app data, ZFS pools, the host SSH key (breaks agenix)."
  echo ""
  echo "   Only meant to turn a bare/minimal VM into {{host}}. To apply a CONFIG change"
  echo "   to an already-running host, cancel and use:  just colmena-apply-host {{host}}"
  echo ""
  if [ "${CONFIRM:-}" != "{{host}}" ]; then
    read -rp "   Type the host name '{{host}}' to REINSTALL it (anything else aborts): " reply
    [ "$reply" = "{{host}}" ] || { echo "Aborted."; exit 1; }
  fi
  echo "Deploying {{host}} to {{ip}}..."
  nixos-anywhere --flake .#{{host}} amadeus@{{ip}}

colmena-apply: clear
  @echo "Deploying to all hosts..."
  colmena apply

colmena-apply-host host: clear
  @echo "Deploying to {{host}}..."
  colmena apply --on {{host}}

colmena-apply-tag tag: clear
  @echo "Deploying to hosts tagged with {{tag}}..."
  colmena apply --on @{{tag}}

colmena-build-host host: clear
  @echo "Building {{host}} configurations..."
  colmena build --on {{host}}

colmena-build: clear
  @echo "Building all configurations..."
  colmena build

colmena-reboot host: clear
  @echo "Rebooting {{host}}..."
  colmena exec --on {{host}} -- sudo reboot

colmena-status: clear
  @echo "Checking host status..."
  colmena exec -- uptime

# OpenTofu/IaC commands (run in iac/ directory)
[working-directory: 'iac']
iac-fmt: clear
  tofu fmt

[working-directory: 'iac']
iac-validate: iac-fmt
  tofu validate

[working-directory: 'iac']
iac-plan: iac-fmt
  tofu plan

[working-directory: 'iac']
iac-apply: iac-validate iac-plan
  tofu apply

[working-directory: 'iac']
iac-destroy: clear
  tofu destroy

# Get SSH host key from a remote host (for agenix secrets.nix)
get-host-key ip:
  @echo "Getting SSH host key from {{ip}}..."
  ssh amadeus@{{ip}} "cat /etc/ssh/ssh_host_ed25519_key.pub"


[working-directory: 'secrets']
reencrypt: clear
  agenix -r -i ~/.config/age/keys.txt

# Raspberry Pi SD image build (specify model: rpi4 or rpi5)
rpi-build model: clear
  @echo "Building Raspberry Pi {{model}} SD image (aarch64)..."
  nix build '.#nixosConfigurations.{{model}}.config.system.build.sdImage' --show-trace

rpi-flash device: clear
  @echo "Flashing SD image to {{device}}..."
  @echo "WARNING: This will overwrite all data on {{device}}"
  @read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
  sudo dd if=result/sd-image/*.img of={{device}} bs=4096 conv=fsync status=progress

# --- Attic binary cache (hosts/cache) -------------------------------------

# ONE-TIME bootstrap: mint an admin token from the atticd signing secret, create
# the `homelab` cache, and mark it public. Public means pulls need no
# credentials, so consumers only need the public key in
# modules/attic-cache.nix — no netrc or agenix secret on every host. Pushing
# still requires the token this prints.
attic-init:
  #!/usr/bin/env bash
  set -euo pipefail
  host=amadeus@192.168.2.175
  echo "==> minting admin token on cache host"
  # Heredoc via `sudo sh -s` so the token-minting script is not mangled by
  # nested shell quoting. atticd-atticadm needs the RS256 secret that the
  # systemd unit gets from environmentFile, hence sourcing it explicitly.
  token=$(ssh "$host" 'sudo sh -s' <<'REMOTE' | tail -1
  set -eu
  set -a
  . /run/agenix/attic-server-token
  set +a
  atticd-atticadm make-token --sub admin --validity 1y \
    --pull '*' --push '*' --delete '*' \
    --create-cache '*' --configure-cache '*' \
    --configure-cache-retention '*' --destroy-cache '*'
  REMOTE
  )
  echo "==> logging in and creating the 'homelab' cache"
  ssh "$host" "attic login homelab https://cache.homelab.local '$token'"
  ssh "$host" "attic cache create homelab || echo '(cache already exists)'"
  ssh "$host" "attic cache configure homelab --public"
  echo
  echo "==> push token (store it; needed by any host that pushes):"
  echo "$token"
  echo
  just attic-info

# Print the cache's public signing key — the value that belongs in
# modules/attic-cache.nix's `publicKey`.
attic-info:
  @ssh amadeus@192.168.2.175 "attic cache info homelab"

# Push a closure to the cache. Defaults to this machine's current system.
# Builds land in the local store first; this uploads them for everyone else.
attic-push path="/run/current-system":
  attic push homelab {{path}}

