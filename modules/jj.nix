{...}: {
  programs.jujutsu = {
    enable = true;
    settings.user = {
      name = "developmentbot";
      email = "developmentbot@homelab.local";
    };
  };
}
