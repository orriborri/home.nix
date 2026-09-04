{
  pkgs,
  lib,
  config,
  ...
}:

let
  isHeadless = config.kirocrew.role == "headless";
  # Fedora's system crypto-policy is newer than the Nix OpenSSH client and can
  # contain algorithms that client cannot parse.  Explicitly selecting the
  # Home Manager config keeps SSH (including editor subprocesses) independent
  # of /etc/ssh/ssh_config while retaining the rest of the OpenSSH tool suite.
  configuredOpenSsh = pkgs.symlinkJoin {
    name = "openssh-configured";
    paths = [ pkgs.openssh ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm "$out/bin/ssh"
      makeWrapper ${pkgs.openssh}/bin/ssh "$out/bin/ssh" \
        --add-flags '-F "$HOME/.ssh/config"'
    '';
  };
in
{
  # Home Manager must replace the regular copy left by the activation below
  # instead of treating it as an unmanaged collision on the next switch.
  home.file.".ssh/config".force = true;

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
    package = configuredOpenSsh;

    extraConfig = ''
      ${lib.optionalString (!isHeadless) ''
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

    settings = {
      "*" = {
        ControlMaster = "auto";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "10m";
      };

      "kirocrew-ec2" = {
        HostName = "i-05d4aaf8ee73fc07f";
        User = "root";
        IdentityFile = "~/.ssh/kirocrew.pem";
        IdentitiesOnly = "yes";
        StrictHostKeyChecking = "accept-new";
        ProxyCommand = "sh -c \"aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --profile Sandbox --region eu-central-1\"";
      };

      # For editor remote development (VS Code, Zed) — connects as orre
      "kirocrew" = {
        HostName = "i-05d4aaf8ee73fc07f";
        User = "orre";
        IdentityFile = "~/.ssh/kirocrew.pem";
        IdentitiesOnly = "yes";
        StrictHostKeyChecking = "accept-new";
        ForwardAgent = "yes";
        ProxyCommand = "sh -c \"aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --profile Sandbox --region eu-central-1\"";
      };
    }
    // lib.optionalAttrs isHeadless {
      # On NixOS (EC2) there are two credential paths for GitLab/GitHub:
      #   1. Interactive (you, over SSM with ForwardAgent): the forwarded
      #      1Password agent signs, gated by an approval prompt on your laptop.
      #   2. Non-interactive (the launcher cloning/pulling as orre at deploy):
      #      the sops-decrypted key at /run/user/<uid>/secrets/git-ssh-key.
      #
      # We therefore keep the sops key as an IdentityFile FALLBACK but do NOT
      # set `IdentitiesOnly = yes` — that flag would force SSH to ignore the
      # agent, locking out the forwarded 1Password path. Without it, SSH offers
      # the forwarded agent first (when present) and falls back to the file,
      # so both the interactive-approve flow and the unattended launcher work.
      # (uid hardcoded to 1001 = orre on the EC2 box.)
      "gitlab.com" = {
        IdentityFile = "/run/user/1001/secrets/git-ssh-key";
        StrictHostKeyChecking = "accept-new";
      };
      "github.com" = {
        IdentityFile = "/run/user/1001/secrets/git-ssh-key";
        StrictHostKeyChecking = "accept-new";
      };
    };
  };

  # Security-related packages
  home.packages =
    with pkgs;
    [
      # Password management
      pass
      passExtensions.pass-otp

      # Security tools
      age # Modern encryption
      sops # Secrets management

      # Network security
      nmap # Network scanning
      # wireshark        # Network analysis (if needed)
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
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
