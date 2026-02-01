set dotenv-load

default:
    just --choose

fmt:
  alejandra .

clear:
  clear

shell:
  nix develop . --command zsh

# NixOS configuration commands
nixos-check:
  @echo "Checking all NixOS configurations..."
  nix flake check

nixos-build-otel:
  @echo "Building otel configuration..."
  nix build .#nixosConfigurations.otel.config.system.build.toplevel

nixos-build-all: nixos-build-otel
  @echo "All configurations built successfully!"

nixos-test host:
  @echo "Dry building {{host}} configuration..."
  nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --dry-run

deploy-database ip:
  @echo "Deploying database to {{ip}}..."
  nixos-anywhere --flake .#database amadeus@{{ip}}
deploy-otel ip:
  @echo "Deploying otel to {{ip}}..."
  nixos-anywhere --flake .#otel amadeus@{{ip}}

deploy-dns ip:
  @echo "Deploying dns to {{ip}}..."
  nixos-anywhere --flake .#dns amadeus@{{ip}}

deploy-unifi ip:
  @echo "Deploying unifi to {{ip}}..."
  nixos-anywhere --flake .#unifi amadeus@{{ip}}

deploy-minimal ip:
  @echo "Deploying minimal to {{ip}}..."
  nixos-anywhere --flake .#minimal amadeus@{{ip}}

# Colmena deployment commands (for updates after initial installation)
colmena-apply: clear
  @echo "Deploying to all hosts..."
  colmena apply

colmena-apply-host host:
  @echo "Deploying to {{host}}..."
  colmena apply --on {{host}}

colmena-apply-tag tag:
  @echo "Deploying to hosts tagged with {{tag}}..."
  colmena apply --on @{{tag}}

colmena-build: clear
  @echo "Building all configurations..."
  colmena build

colmena-build-host host:
  @echo "Building {{host}} configuration..."
  colmena build --on {{host}}

colmena-diff:
  @echo "Showing differences for all hosts..."
  colmena apply --dry-activate

colmena-diff-host host:
  @echo "Showing differences for {{host}}..."
  colmena apply --on {{host}} --dry-activate

colmena-reboot host:
  @echo "Rebooting {{host}}..."
  colmena exec --on {{host}} -- sudo reboot

colmena-status:
  @echo "Checking host status..."
  colmena exec -- uptime
