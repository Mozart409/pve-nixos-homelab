# Zsh tab-completion for `just`, system-wide.
#
# The `just` binary itself is deliberately NOT installed here: every repo under
# ~/code gets it from its own flake dev shell (entered automatically by direnv,
# see hosts/development/configuration.nix), so a system-wide copy would only add
# a second version to drift against. What a dev shell cannot provide is the
# completion function — zsh builds its fpath and runs compinit at login, long
# before direnv rewrites PATH — so only `_just` is linked into the system
# profile, from the same nixpkgs `just` the dev shells use.
#
# programs.zsh.enableCompletion (modules/common.nix) is what puts
# /run/current-system/sw/share/zsh/site-functions on fpath and runs compinit.
#
# `_just` shells out to `just --summary` to list a justfile's recipes, so recipe
# names only complete where the dev shell has put just on PATH; flags and
# options complete anywhere.
{pkgs, ...}: {
  environment.systemPackages = [
    (pkgs.runCommand "just-zsh-completions" {} ''
      install -Dm444 ${pkgs.just}/share/zsh/site-functions/_just \
        $out/share/zsh/site-functions/_just
    '')
  ];
}
