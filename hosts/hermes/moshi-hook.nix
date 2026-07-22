{
  config,
  lib,
  pkgs,
  ...
}: let
  # moshi-hook: companion daemon for the Moshi iOS app (getmoshi.app). It runs a
  # loopback gateway on 127.0.0.1:24543 and holds a WebSocket to Moshi's relay so
  # coding agents (incl. "hermes") can push approvals / turn-completion / errors /
  # usage to the phone. Upstream ships no nixpkgs package; this pins the prebuilt
  # GoReleaser tarball. Bump `version` + `sha256` from the rjyo/homebrew-moshi
  # formula (https://github.com/rjyo/homebrew-moshi) when updating.
  moshi-hook = pkgs.stdenv.mkDerivation rec {
    pname = "moshi-hook";
    version = "0.2.58";
    src = pkgs.fetchurl {
      url = "https://cdn.getmoshi.app/hook/v${version}/moshi-hook_Linux_x86_64.tar.gz";
      sha256 = "638046c07451e0ce15b0b7ffb6fc2d77d6fd647ba28715511357759cf2b34585";
    };
    sourceRoot = ".";
    # The upstream binary is a statically linked (CGO-disabled) Go executable, so
    # it runs on NixOS as-is — no autoPatchelfHook / interpreter fixup needed. If
    # a future release switches to dynamic linking, add `autoPatchelfHook` to
    # nativeBuildInputs and `stdenv.cc.cc.lib` to buildInputs.
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m0755 moshi-hook $out/bin/moshi-hook
      ln -s moshi-hook $out/bin/moshi
      runHook postInstall
    '';
  };
in {
  # Available on PATH for the one-time `moshi-hook pair --token <TOKEN>` bootstrap
  # and for `moshi-hook install` (agent hook wiring).
  environment.systemPackages = [moshi-hook];

  # Runs `moshi-hook serve` as the hermes agent user. Pairing is a one-time manual
  # step (from the Moshi app); its credentials persist in the StateDirectory, which
  # is why HOME is pointed there:
  #   sudo -u hermes env HOME=/var/lib/moshi-hook moshi-hook pair --token <TOKEN>
  #   sudo systemctl restart moshi-hook
  # No firewall change is needed: the gateway is loopback-only and the app reaches
  # it over the existing mosh/SSH-over-Tailscale session.
  systemd.services.moshi-hook = {
    description = "Moshi agent hook daemon";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    path = [moshi-hook];
    environment.HOME = "/var/lib/moshi-hook";
    serviceConfig = {
      User = "hermes";
      Group = "hermes";
      ExecStart = "${moshi-hook}/bin/moshi-hook serve";
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "moshi-hook";
      StateDirectoryMode = "0700";
    };
  };
}
