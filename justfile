set dotenv-load

default:
    just --choose

fmt:
  alejandra .

clear:
  clear

shell:
  nix develop . --command zsh

tofu-fmt:
  tofu -chdir=./iac/ fmt

tofu-validate: tofu-fmt
  tofu -chdir=./iac/ validate

plan:
  tofu -chdir=./iac/ plan

apply: tofu-validate plan
  tofu -chdir=./iac/ apply

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

# Deploy with nixos-anywhere (initial installation)
deploy-ferron ip:
  nixos-anywhere --flake .#ferron root@{{ip}}

deploy-caddy ip:
  nixos-anywhere --flake .#caddy root@{{ip}}

deploy-database ip:
  nixos-anywhere --flake .#database root@{{ip}}

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
