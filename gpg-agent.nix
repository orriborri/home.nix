{
  pkgs,
  lib,
  config,
  ...
}:

{
  # GPG Agent configuration (Linux desktops only: pinentry-gnome3 pulls GTK/gcr
  # into the closure and cannot prompt on the headless EC2 host)
  services.gpg-agent =
    lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && config.kirocrew.role != "headless")
      {
        enable = true;
        enableZshIntegration = true;
        enableSshSupport = false; # Disabled — 1Password handles SSH agent
        pinentry.package = pkgs.pinentry-gnome3;

        # Cache settings
        defaultCacheTtl = 1800; # 30 minutes
        maxCacheTtl = 7200; # 2 hours
      };
}
