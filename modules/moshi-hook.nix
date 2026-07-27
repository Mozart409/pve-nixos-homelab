{pkgs, ...}: {
  # moshi-hook: companion daemon for the Moshi iOS app (getmoshi.app). Upstream
  # ships no nixpkgs package; this pins the prebuilt GoReleaser tarball. Bump
  # `version` + `sha256` from the rjyo/homebrew-moshi formula
  # (https://github.com/rjyo/homebrew-moshi) when updating.
  #
  # NB on bumping `version`: hosts/hermes/moshi-hook.nix stamps `moshi-hook
  # install` per-version, so a bump re-runs it on the next hermes deploy — and
  # `install` rewrites hermes' config.yaml with a list indent that collides with
  # `hermes-config-merge`, corrupting the file. `hermes-config-check` repairs it
  # before hermes-agent starts, so this is safe; expect a "repaired mixed-indent"
  # line in that unit's journal. See AGENTS.md §6 "Hermes Fails OPEN on a
  # Malformed config.yaml".
  #
  # Package only, exposed as `pkgs.moshi-hook` via overlay so every host that
  # imports this module can reference the same derivation from its own file
  # (pair/install/serve wiring stays per-host — see hosts/hermes/moshi-hook.nix
  # and modules/moshi-hook-user.nix).
  nixpkgs.overlays = [
    (final: prev: {
      moshi-hook = prev.stdenv.mkDerivation rec {
        pname = "moshi-hook";
        version = "0.2.59";
        src = prev.fetchurl {
          url = "https://cdn.getmoshi.app/hook/v${version}/moshi-hook_Linux_x86_64.tar.gz";
          sha256 = "2a7c41bb119d293de6dd5ce82e71381cd8a2dd6d2a543a7d188e605fed6a5446";
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
