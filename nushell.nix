{ pkgs, ... }:

{
  enable = true;

  extraConfig = ''
<<<<<<< HEAD
    $env.config = ($env.config | upsert show_banner false)
    $env.config = ($env.config | upsert edit_mode vi)
||||||| parent of 03f0edf (fix: don't include binutils as it provides ld from nixpkgs)
    let carapace_completer = {|spans| 
      carapace $spans.0 nushell $spans | from json
    }

    let-env config = {
      show_banner: false,
      edit_mode: vi,

      hooks: {
        pre_prompt: [{ ||
          let direnv = (direnv export json | from json)
          let direnv = if ($direnv | length) == 1 { $direnv } else { {} }
          $direnv | load-env
        }]
      },

      completions: {
        external: {
          enable: true
          completer: $carapace_completer
        }
      }
    }
=======
    let carapace_completer = {|spans| 
      carapace $spans.0 nushell $spans | from json
    }

    $env.config = {
      show_banner: false,
      edit_mode: vi,

      hooks: {
        pre_prompt: [{ ||
          let direnv = (direnv export json | from json)
          let direnv = if ($direnv | length) == 1 { $direnv } else { {} }
          $direnv | load-env
        }]
      },

      completions: {
        external: {
          enable: true
          completer: $carapace_completer
        }
      }
    }
>>>>>>> 03f0edf (fix: don't include binutils as it provides ld from nixpkgs)

    alias da = direnv allow
    alias g = git
    # Define a custom command for `gui`
    def gui [] {
      bash -c 'eval $(ssh-agent) && ssh-add ~/.ssh/id_rsa && gitui && eval $(ssh-agent -k)'
    }
    alias c = code-insiders

<<<<<<< HEAD
    # Maybe these won't be needed one day
    alias ls = lsd
    alias l = ls -l
    alias la = ls -a
    alias lla = ls -la
    alias lt = ls --tree
    alias ssh = ssh.exe
    alias ssh-add = ssh-add.exe
    alias scp = scp.exe
||||||| parent of 03f0edf (fix: don't include binutils as it provides ld from nixpkgs)
    let-env EDITOR = nvim
=======
    $env.EDITOR = nvim
>>>>>>> 03f0edf (fix: don't include binutils as it provides ld from nixpkgs)
  '';

  extraEnv = ''
    if (not (($env | get SSH_AUTH_SOCK?) | default false)) {
      $env.HOME + '/.agent-brigde.nu'
    }
    $env.EDITOR = 'nvim'
    $env.LS_COLORS = (${pkgs.vivid}/bin/vivid generate nord | str trim)
    $env.CARGO_HOME = ($env.HOME | path join .cargo)
    $env.PATH = (
      $env.PATH | split row (char esep)
        | append /usr/local/bin
        | append ($env.CARGO_HOME | path join bin)
        | append ($env.HOME | path join .local bin)
        | uniq # filter so the paths are unique
    )
  '';
}
