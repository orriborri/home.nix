{ pkgs, lib, ... }:

{
  # GPG Agent configuration (Linux only)
  services.gpg-agent = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    enableZshIntegration = true;
    enableSshSupport = true;
    pinentry.package = pkgs.pinentry-gtk2;
    
    # Cache settings
    defaultCacheTtl = 1800;      # 30 minutes
    defaultCacheTtlSsh = 1800;   # 30 minutes
    maxCacheTtl = 7200;          # 2 hours
    maxCacheTtlSsh = 7200;       # 2 hours
  };
}
