set dotenv-load

default:
    just --choose

clear:
  clear

shell:
  nix develop . --command zsh

tofu-fmt:
  tofu fmt 
