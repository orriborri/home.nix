{ pkgs, lib, ... }:

{
  # GPG configuration
  programs.gpg = {
    enable = true;
    settings = {
      # Use stronger algorithms
      personal-cipher-preferences = "AES256 AES192 AES";
      personal-digest-preferences = "SHA512 SHA384 SHA256";
      personal-compress-preferences = "ZLIB BZIP2 ZIP Uncompressed";
      
      # Security settings
      default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";
      cert-digest-algo = "SHA512";
      s2k-digest-algo = "SHA512";
      s2k-cipher-algo = "AES256";
      charset = "utf-8";
      
      # UI settings
      fixed-list-mode = true;
      no-comments = true;
      no-emit-version = true;
      keyid-format = "0xlong";
      list-options = "show-uid-validity";
      verify-options = "show-uid-validity";
      with-fingerprint = true;
      use-agent = true;
    };
  };

  # Password management
  programs.password-store = {
    enable = true;
    settings = {
      PASSWORD_STORE_CLIP_TIME = "45";
      PASSWORD_STORE_GENERATED_LENGTH = "25";
    };
  };

  # SSH configuration
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    # Default match block for all hosts
    matchBlocks."*" = {
      controlMaster = "auto";
      controlPath = "~/.ssh/master-%r@%n:%p";
      controlPersist = "10m";
      extraOptions = {
        Protocol = "2";
        Ciphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr";
        MACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512";
        KexAlgorithms = "curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512";
        HostKeyAlgorithms = "ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com,ssh-ed25519,ssh-rsa";
        ServerAliveInterval = "60";
        ServerAliveCountMax = "3";
        TCPKeepAlive = "yes";
        HashKnownHosts = "yes";
        VerifyHostKeyDNS = "ask";
        StrictHostKeyChecking = "ask";
        Compression = "yes";
      };
    };
  };

  # Security-related packages
  home.packages = with pkgs; [
    # Password management
    pass
    passExtensions.pass-otp
    
    # Security tools
    age              # Modern encryption
    sops             # Secrets management
    
    # Network security
    nmap             # Network scanning
    # wireshark        # Network analysis (if needed)
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    # Linux-specific security tools
    lynis            # Security auditing
  ];

  # Environment variables for security tools
  home.sessionVariables = {
    # GPG settings
    GPG_TTY = "$(tty)";
    
    # Password store settings
    PASSWORD_STORE_ENABLE_EXTENSIONS = "true";
  };
}
