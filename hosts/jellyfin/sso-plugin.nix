{
  config,
  pkgs,
  ...
}: let
  version = "5.0.0.0";

  # K0lin/jellyfin-plugin-sso — the maintained fork of the archived
  # 9p4/jellyfin-plugin-sso. targetAbi 10.11.11.0 matches
  # services.jellyfin.package (10.11.11). Pocket ID is a tested OIDC provider.
  ssoPlugin = pkgs.fetchzip {
    url = "https://github.com/K0lin/jellyfin-plugin-sso/releases/download/v${version}/sso-authentication_${version}.zip";
    sha256 = "00vmj5vkvk9jxd68pqrir0zz58kz00mw35drwqcxwb8vfq0rmmwv";
    stripRoot = false; # DLLs + meta.json sit at the zip root
  };

  dataDir = config.services.jellyfin.dataDir;
  pluginDir = "${dataDir}/plugins/SSO-Auth_${version}";
in {
  # Jellyfin has no declarative plugin option, so we copy the pinned plugin into
  # its (mutable) state dir before the service starts. We copy rather than
  # symlink so Jellyfin can write plugin status back into meta.json. The
  # Condition makes this a no-op once installed (preserving that runtime state);
  # a version bump changes the path and re-provisions, dropping the old copy.
  #
  # Plugin *configuration* (Pocket ID endpoint, client id/secret, role claims)
  # is entered once in the Jellyfin web UI — there is no config-file interface,
  # so it necessarily lives in Jellyfin's state, not here.
  systemd.services.jellyfin-sso-plugin = {
    description = "Provision Jellyfin SSO/OIDC plugin ${version}";
    wantedBy = ["jellyfin.service"];
    before = ["jellyfin.service"];
    unitConfig.ConditionPathExists = "!${pluginDir}/meta.json";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -o jellyfin -g jellyfin -m 0700 ${dataDir}
      install -d -o jellyfin -g jellyfin -m 0700 ${dataDir}/plugins
      # Drop any previously pinned version, then install this one.
      rm -rf ${dataDir}/plugins/SSO-Auth_*
      install -d -o jellyfin -g jellyfin -m 0755 ${pluginDir}
      cp -r ${ssoPlugin}/* ${pluginDir}/
      chown -R jellyfin:jellyfin ${pluginDir}
      chmod -R u+w ${pluginDir}
    '';
  };
}
