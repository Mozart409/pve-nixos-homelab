{lib, ...}: {
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.sshCommand = "ssh -o ConnectTimeout=5";
    };
    ignores = [
      "*~"
      "*.swp"
    ];
  };
}
