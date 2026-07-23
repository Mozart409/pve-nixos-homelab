{pkgs, ...}: {
  # moshi-hook: companion daemon for the Moshi iOS app (getmoshi.app). Upstream
  # ships no nixpkgs package; this pins the prebuilt GoReleaser tarball. Bump
  # `version` + `sha256` from the rjyo/homebrew-moshi formula
  # (https://github.com/rjyo/homebrew-moshi) when updating.
  #
  # Package only, exposed as `pkgs.moshi-hook` via overlay so every host that
  # imports this module can reference the same derivation from its own file
  # (pair/install/serve wiring stays per-host — see hosts/hermes/moshi-hook.nix
  # and modules/moshi-hook-user.nix).
  nixpkgs.overlays = [
    (final: prev: {
      moshi-hook = prev.stdenv.mkDerivation rec {
        pname = "moshi-hook";
        version = "0.2.58";
        src = prev.fetchurl {
          url = "https://cdn.getmoshi.app/hook/v${version}/moshi-hook_Linux_x86_64.tar.gz";
          sha256 = "638046c07451e0ce15b0b7ffb6fc2d77d6fd647ba28715511357759cf2b34585";
        };
        sourceRoot = ".";
        dontStrip = true;
        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin
          install -m0755 moshi-hook $out/bin/moshi-hook
          ln -s moshi-hook $out/bin/moshi
          runHook postInstall
        '';
      };
    })
  ];

  environment.systemPackages = [pkgs.moshi-hook];
}
