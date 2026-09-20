{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  nodejs,
  makeBinaryWrapper,
  ripgrep,
  wayland,
  installShellFiles,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
# OpenCode v2 derivation — built from the v2 branch source.
# Note: v2 pre-built binaries are currently broken (serve bun instead of opencode).
# This builds from source using the upstream nix approach.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode-v2";
  version = "2.0.0-pre";

  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    rev = "refs/heads/v2";
    hash = "sha256-0TWksTXb+s+3+EJSycXeNMDTNA/tHGU8VxBnH9ktz00=";
  };

  # NOTE: node_modules is built as a fixed-output derivation upstream.
  # We inline a simplified version here to avoid the complex two-derivation setup.
  # This will re-download deps on every rebuild but is more reliable.
  node_modules = stdenvNoCC.mkDerivation {
    pname = "${finalAttrs.pname}-node_modules";
    inherit (finalAttrs) version src;

    nativeBuildInputs = [bun writableTmpDirAsHomeHook];
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
      bun install \
        --cpu="x64" \
        --os="linux" \
        --filter '!./' \
        --filter './packages/cli' \
        --filter './packages/desktop' \
        --filter './packages/app' \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      find . -type d -name node_modules -exec cp -R --parents {} $out \;
      runHook postInstall
    '';

    dontFixup = true;

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    # This hash will need updating when the v2 branch changes.
    # First build will fail and report the correct hash.
    outputHash = "sha256-jxjmjo7hdD5fBNePVNcBsb844VUWprRpwwPb86GvgF8=";
  };

  nativeBuildInputs = [
    bun
    nodejs
    installShellFiles
    makeBinaryWrapper
    writableTmpDirAsHomeHook
  ];

  postPatch = ''
    substituteInPlace packages/script/src/index.ts \
      --replace-fail 'throw new Error(`This script requires bun@''${expectedBunVersionRange}' \
                     'console.warn(`Warning: This script requires bun@''${expectedBunVersionRange}'
  '';

  configurePhase = ''
    runHook preConfigure
    cp -R ${finalAttrs.node_modules}/. .
    patchShebangs node_modules
    patchShebangs packages/*/node_modules
    runHook postConfigure
  '';

  env.OPENCODE_DISABLE_MODELS_FETCH = "true";
  env.OPENCODE_VERSION = finalAttrs.version;
  env.OPENCODE_CHANNEL = "prod";
  env.NODE_OPTIONS = "--max-old-space-size=4096";

  buildPhase = ''
    runHook preBuild
    cd ./packages/cli
    bun --bun ./script/build.ts --single --skip-install
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 dist/cli-*/bin/opencode $out/bin/opencode

    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ripgrep]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [wayland]}

    ln -s opencode $out/bin/opencode2
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd opencode \
      --bash <($out/bin/opencode completion) \
      --zsh <(SHELL=/bin/zsh $out/bin/opencode completion)

    installShellCompletion --cmd opencode2 \
      --bash <($out/bin/opencode2 completion) \
      --zsh <(SHELL=/bin/zsh $out/bin/opencode2 completion)
  '';

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = ["HOME" "OPENCODE_DISABLE_MODELS_FETCH"];
  versionCheckProgramArg = "--version";

  meta = {
    description = "OpenCode v2 — the open source AI coding agent (built from v2 branch)";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
  };
})
