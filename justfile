set dotenv-load

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

deploy-minimal ip:
  @echo "Deploying minimal to {{ip}}..."
  nixos-anywhere --flake .#minimal amadeus@{{ip}}

colmena-apply: clear
  @echo "Deploying to all hosts..."
  colmena apply

colmena-apply-host host: clear
  @echo "Deploying to {{host}}..."
  colmena apply --on {{host}}

colmena-apply-tag tag: clear
  @echo "Deploying to hosts tagged with {{tag}}..."
  colmena apply --on @{{tag}}

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
