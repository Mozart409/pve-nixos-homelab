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

nixos-build-ferron:
  @echo "Building ferron configuration..."
  nix build .#nixosConfigurations.ferron.config.system.build.toplevel

nixos-build-caddy:
  @echo "Building caddy configuration..."
  nix build .#nixosConfigurations.caddy.config.system.build.toplevel

nixos-build-database:
  @echo "Building database configuration..."
  nix build .#nixosConfigurations.database.config.system.build.toplevel

nixos-build-all: nixos-build-ferron nixos-build-caddy nixos-build-database
  @echo "All configurations built successfully!"

nixos-test host:
  @echo "Dry building {{host}} configuration..."
  nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --dry-run


deploy-ferron ip:
  @echo "Deploying ferron to {{ip}}..."
  nixos-anywhere --flake .#ferron --build-on-remote amadeus@{{ip}}

deploy-caddy ip:
  @echo "Deploying caddy to {{ip}}..."
  nixos-anywhere --flake .#caddy --build-on-remote amadeus@{{ip}}

deploy-database ip:
  @echo "Deploying database to {{ip}}..."
  nixos-anywhere --flake .#database --build-on-remote amadeus@{{ip}}

# Colmena deployment commands (for updates after initial installation)
colmena-apply:
  @echo "Deploying to all hosts..."
  colmena apply

colmena-apply-host host:
  @echo "Deploying to {{host}}..."
  colmena apply --on {{host}}

colmena-apply-tag tag:
  @echo "Deploying to hosts tagged with {{tag}}..."
  colmena apply --on @{{tag}}

colmena-build:
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
