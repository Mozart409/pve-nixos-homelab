{pkgs, ...}: let
  # ElegantFin — a pure-CSS reskin of the stock Jellyfin web client.
  # https://github.com/lscambo13/ElegantFin
  #
  # Pinned to the v26.09.05 release *commit*, not the tag: tags are mutable on
  # GitHub, commits are not. Bumping = change rev + version, then re-run
  # `nix-prefetch-url` for the stylesheet below.
  #
  # v26.09.05 is the first release with Jellyfin 12 compatibility fixes; keep
  # it at or above that while services.jellyfin.package is on 12.x.
  rev = "5efc1105e9a56424d2252d73c04cafe484fb9e92";
  version = "v26.09.05";

  # Upstream ships its two add-ons (media-bar plugin support, custom media
  # covers) as commented-out @imports — opt-in, off by default — so we ship
  # only the main stylesheet.
  themeCss = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/lscambo13/ElegantFin/${rev}/Theme/ElegantFin-theme-${version}.css";
    hash = "sha256-IVXd7FRxZnXok4qst0rWb6qLZ5MkW4REMq/U6CGaimY=";
  };

  # Fonts: keep Google out of the client. Upstream @imports Inter from
  # fonts.googleapis.com and pins two Material Symbols icon fonts straight to
  # fonts.gstatic.com. The Inter import is rerouted to the coollabs proxy
  # (api.fonts.coollabs.io serves Google's CSS with the font files rehosted on
  # cdn.fonts.coollabs.io; if unreachable the client falls back to the system
  # font). coollabs does NOT mirror gstatic's /l/ and /s/ paths, so the two icon
  # fonts are vendored into the store at build time instead and the @font-face
  # src rewritten to local paths. The payloads are UA-independent, so the
  # pinned hashes are stable; a change upstream fails the build loudly.
  #
  # "Minimal" is the icon_names-subsetted variant the theme uses for its own
  # UI; the full face is the fallback for everything else.
  materialSymbolsMinimalUrl = "https://fonts.gstatic.com/l/font?kit=sykg-zNym6YjUruM-QrEh7-nyTnjDwKNJ_190FjzarESMdAUY9qjb3u1M7e05tMSFFiwiIx7ihGnzWmz-lkbjBJUko54uQNlqhKP2qww7THOuDASqI-hkRJowUB4AMXqmksLbVSypWpZCoCuR4ppEVE-Vm2EBGaEWVT1QQVqin1CJL8x-Ze-xGUuG3wq4dfIUCyyVOwlP0NhUaux0cITqh7BYw&skey=70ddea8fe54d532e&v=v362";
  materialSymbolsMinimal = pkgs.fetchurl {
    name = "material-symbols-rounded-minimal-v362.woff2";
    url = materialSymbolsMinimalUrl;
    hash = "sha256-XuZQVGgsWRsO4JPzB48VVjQfHT3YzUma95oUJDHRaak=";
  };
  materialSymbolsFullUrl = "https://fonts.gstatic.com/s/materialsymbolsrounded/v362/sykg-zNym6YjUruM-QrEh7-nyTnjDwKNJ_190Fjzag.woff2";
  materialSymbolsFull = pkgs.fetchurl {
    name = "material-symbols-rounded-v362.woff2";
    url = materialSymbolsFullUrl;
    hash = "sha256-m+gSZVPo99+A9Gdq+Ab3suZNSohQ2lAlQi9V2ro8txo=";
  };

  # Copy the prebuilt jellyfin-web output and add the theme, rather than
  # overrideAttrs'ing jellyfin-web — that would re-run the full npm production
  # build locally on every nixpkgs bump for what is ultimately a stylesheet.
  #
  # The theme lives in its own elegantfin/ subdir so it can never collide with
  # the webdir's own top-level files (assets/, etc.).
  themedWeb = pkgs.runCommand "jellyfin-web-elegantfin-${version}" {} ''
    mkdir -p $out/share
    cp -r ${pkgs.jellyfin-web}/share/jellyfin-web $out/share/jellyfin-web
    chmod -R u+w $out/share/jellyfin-web

    install -Dm444 ${themeCss}               $out/share/jellyfin-web/elegantfin/theme.css
    install -Dm444 ${materialSymbolsMinimal} $out/share/jellyfin-web/elegantfin/fonts/material-symbols-rounded-minimal.woff2
    install -Dm444 ${materialSymbolsFull}    $out/share/jellyfin-web/elegantfin/fonts/material-symbols-rounded.woff2
    chmod u+w $out/share/jellyfin-web/elegantfin/theme.css

    # replace-fail on every font reference: if upstream changes how it loads
    # fonts, the build breaks instead of silently shipping a Google-backed
    # client again.
    substituteInPlace $out/share/jellyfin-web/elegantfin/theme.css \
      --replace-fail 'https://fonts.googleapis.com/css2?family=Inter' \
        'https://api.fonts.coollabs.io/css2?family=Inter' \
      --replace-fail '${materialSymbolsMinimalUrl}' './fonts/material-symbols-rounded-minimal.woff2' \
      --replace-fail '${materialSymbolsFullUrl}' './fonts/material-symbols-rounded.woff2'

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
