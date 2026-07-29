{pkgs, ...}: let
  # ElegantFin — a pure-CSS reskin of the stock Jellyfin web client.
  # https://github.com/lscambo13/ElegantFin
  #
  # Pinned to the v26.06.06 release *commit*, not the tag: tags are mutable on
  # GitHub, commits are not. Bumping = change rev + version, then re-run
  # `nix-prefetch-url` for each of the three files below.
  rev = "c8ef5af7dec8eff49667b0ed9da829de22fc5081";
  version = "v26.06.06";

  fetchTheme = {
    path,
    hash,
  }:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/lscambo13/ElegantFin/${rev}/${path}";
      inherit hash;
    };

  # The upstream CSS pulls two add-ons in via @import. We fetch them at the same
  # pinned rev and rewrite the imports to local paths below, so a running client
  # never depends on jsDelivr (and a CDN change can't alter what we ship).
  themeCss = fetchTheme {
    path = "Theme/ElegantFin-theme-${version}.css";
    hash = "sha256-0JEiTxVoA0rj8YTKdi4wGYaehpC3oFJGuGSrH9mj8LY=";
  };
  mediaBarCss = fetchTheme {
    path = "Theme/assets/add-ons/media-bar-plugin-support-nightly.css";
    hash = "sha256-4yeMjvamuX7fUYfXHlZWGbSJQphGI4fbWxeKgj9Tq4o=";
  };
  mediaCoversCss = fetchTheme {
    path = "Theme/assets/add-ons/custom-media-covers-latest-min.css";
    hash = "sha256-Vt3/bXXBxgANuaZ+ggR14Qd7bfLdgz85Gqd2/WC1CN4=";
  };

  # Copy the prebuilt jellyfin-web output and add the theme, rather than
  # overrideAttrs'ing jellyfin-web — that would re-run the full npm production
  # build locally on every nixpkgs bump for what is ultimately a stylesheet.
  #
  # The theme lives in its own elegantfin/ subdir: the webdir root already has
  # an assets/ directory, and the theme's @imports are relative to itself.
  themedWeb = pkgs.runCommand "jellyfin-web-elegantfin-${version}" {} ''
    mkdir -p $out/share
    cp -r ${pkgs.jellyfin-web}/share/jellyfin-web $out/share/jellyfin-web
    chmod -R u+w $out/share/jellyfin-web

    install -Dm444 ${themeCss}       $out/share/jellyfin-web/elegantfin/theme.css
    install -Dm444 ${mediaBarCss}    $out/share/jellyfin-web/elegantfin/assets/add-ons/media-bar-plugin-support-nightly.css
    install -Dm444 ${mediaCoversCss} $out/share/jellyfin-web/elegantfin/assets/add-ons/custom-media-covers-latest-min.css
    chmod u+w $out/share/jellyfin-web/elegantfin/theme.css

    # Repoint the one CDN @import at our pinned local copy. The other @import is
    # already relative and resolves inside elegantfin/ as-is.
    substituteInPlace $out/share/jellyfin-web/elegantfin/theme.css \
      --replace-fail \
        'url("https://cdn.jsdelivr.net/gh/lscambo13/ElegantFin@main/Theme/assets/add-ons/custom-media-covers-latest-min.css")' \
        'url("./assets/add-ons/custom-media-covers-latest-min.css")'

    # replace-fail: if upstream jellyfin-web ever restructures index.html, the
    # build breaks loudly instead of silently shipping an unthemed client.
    substituteInPlace $out/share/jellyfin-web/index.html \
      --replace-fail '</head>' \
        '<link rel="stylesheet" href="elegantfin/theme.css"></head>'
  '';
in {
  # services.jellyfin.package is a wrapper whose only tie to the frontend is
  # `--webdir=''${jellyfin-web}/share/jellyfin-web`, and jellyfin-web is a plain
  # function argument — so overriding it swaps the UI declaratively, with no
  # mutable state in dataDir. This is deliberately NOT the Dashboard > General >
  # "Custom CSS" box: that persists into branding.xml inside Jellyfin's state
  # dir, i.e. outside this repo (same class of problem ./sso-plugin.nix documents
  # for plugin settings).
  services.jellyfin.package = pkgs.jellyfin.override {jellyfin-web = themedWeb;};
}
