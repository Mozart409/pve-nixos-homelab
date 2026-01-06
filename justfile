set dotenv-load

default:
    just --choose

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
  tofu -chdir=./iac/ plan
