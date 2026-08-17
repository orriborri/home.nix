{ pkgs, lib, config, ... }:

let
  isNixOS = builtins.pathExists /etc/NIXOS;
in
{
  # Fix SSH config permissions: HM creates a symlink to the Nix store which
  # OpenSSH rejects ("Bad owner or permissions"). Replace it with a copy
  # that has 0600 permissions after each activation.
  home.activation.fixSshConfigPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -L "$HOME/.ssh/config" ]; then
      target=$(readlink -f "$HOME/.ssh/config")
      if [ -f "$target" ]; then
        rm "$HOME/.ssh/config"
        cp "$target" "$HOME/.ssh/config"
        chmod 600 "$HOME/.ssh/config"
      fi
    fi
  '';
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
    package = pkgs.openssh;
    
    extraConfig = ''
      ${lib.optionalString (!isNixOS) ''
      # 1Password SSH agent (desktop only — not available on headless NixOS)
      IdentityAgent "~/.1password/agent.sock"
      ''}
      # Ignore unknown options from system crypto-policies (Fedora)
      IgnoreUnknown GSSAPIKexAlgorithms

      # Security settings
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
      MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512
      KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
      HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
      
      # Connection settings
      ServerAliveInterval 60
      ServerAliveCountMax 3
      TCPKeepAlive yes
      
      # Security
      HashKnownHosts yes
      VerifyHostKeyDNS ask
      StrictHostKeyChecking ask
      
      # Performance
      Compression yes
    '';
    
    # Disable deprecated default config, use settings instead
    enableDefaultConfig = false;

    settings."*" = {
      ControlMaster = "auto";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "10m";
    };

    matchBlocks."kirocrew-ec2" = {
      hostname = "i-05d4aaf8ee73fc07f";
      user = "root";
      identityFile = "~/.ssh/kirocrew.pem";
      extraOptions = {
        IdentitiesOnly = "yes";
        StrictHostKeyChecking = "accept-new";
      };
      proxyCommand = "sh -c \"aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --profile Sandbox --region eu-central-1\"";
    };

    # For editor remote development (VS Code, Zed) — connects as orre
    matchBlocks."kirocrew" = {
      hostname = "i-05d4aaf8ee73fc07f";
      user = "orre";
      identityFile = "~/.ssh/kirocrew.pem";
      extraOptions = {
        IdentitiesOnly = "yes";
        StrictHostKeyChecking = "accept-new";
        ForwardAgent = "yes";
      };
      proxyCommand = "sh -c \"aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --profile Sandbox --region eu-central-1\"";
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
    #lynis            # Security auditing
  ];

  # Environment variables for security tools
  home.sessionVariables = {
    # GPG settings
    GPG_TTY = "$(tty)";
    
    # Password store settings
    PASSWORD_STORE_ENABLE_EXTENSIONS = "true";
  };
}
