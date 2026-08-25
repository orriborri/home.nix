{ pkgs, lib, ... }:

{
  # GPG Agent configuration (Linux only)
  services.gpg-agent = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    enable = true;
    enableZshIntegration = true;
    enableSshSupport = false;  # Disabled — 1Password handles SSH agent
    pinentry.package = pkgs.pinentry-gnome3;
    
    # Cache settings
    defaultCacheTtl = 1800;      # 30 minutes
    defaultCacheTtlSsh = 1800;   # 30 minutes
    maxCacheTtl = 7200;          # 2 hours
    maxCacheTtlSsh = 7200;       # 2 hours
  };
}
