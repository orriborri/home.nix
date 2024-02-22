{ pkgs, ... }:

{
  enable = true;

  extraConfig = ''
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

    alias da = direnv allow
    alias g = git
    # Define a custom command for `gui`
    def gui [] {
      bash -c 'eval $(ssh-agent) && ssh-add ~/.ssh/id_rsa && gitui && eval $(ssh-agent -k)'
    }
    alias c = code-insiders

    $env.EDITOR = nvim
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
