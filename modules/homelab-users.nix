{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.users;
in {
  options.homelab.users = lib.mkOption {
    default = {};
    description = ''
      Interactive (human) user accounts. Declared here rather than as raw
      `users.users` entries so any host -- or the installer ISO -- can add
      another person with their own SSH keys by adding one attribute, without
      repeating the isNormalUser/shell/authorizedKeys boilerplate. Merges by
      key across modules, so modules/common.nix and a host config can each
      contribute users. Service accounts stay plain `users.users`.
    '';
    example = lib.literalExpression ''
      {
        alice = {
          isAdmin = true;
          sshKeys = ["ssh-ed25519 AAAA... alice@laptop"];
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        description = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "GECOS description for the account.";
        };
        sshKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Public keys placed in the user's authorized_keys.";
        };
        extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Groups beyond wheel (which isAdmin adds on its own).";
        };
        isAdmin = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Add the user to wheel. Combined with security.sudo.wheelNeedsPassword = false in modules/common.nix this means passwordless sudo.";
        };
        shell = lib.mkOption {
          type = lib.types.package;
          default = pkgs.zsh;
          description = "Login shell.";
        };
      };
    }));
  };

  config.users.users =
    lib.mapAttrs (_name: user: {
      isNormalUser = true;
      inherit (user) description shell;
      extraGroups = user.extraGroups ++ lib.optional user.isAdmin "wheel";
      openssh.authorizedKeys.keys = user.sshKeys;
    })
    cfg;
}
