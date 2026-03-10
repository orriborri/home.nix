{ ... }:

{
  # Zellij layout for Neovim + Kiro CLI development
  home.file.".config/zellij/layouts/kiro-dev.kdl".text = ''
    layout {
      default_tab_template {
        pane size=1 borderless=true {
          plugin location="zellij:tab-bar"
        }
        children
        pane size=2 borderless=true {
          plugin location="zellij:status-bar"
        }
      }

      tab name="dev" {
        pane split_direction="vertical" {
          pane size="55%" {
            command "nvim"
          }
          pane size="45%" split_direction="horizontal" {
            pane size="70%" {
              command "kiro-cli"
              args "chat"
            }
            pane size="30%" {
              // Terminal for running commands
            }
          }
        }
      }
    }
  '';

  # Zellij layout for Neovim + terminal only
  home.file.".config/zellij/layouts/vim-dev.kdl".text = ''
    layout {
      default_tab_template {
        pane size=1 borderless=true {
          plugin location="zellij:tab-bar"
        }
        children
        pane size=2 borderless=true {
          plugin location="zellij:status-bar"
        }
      }

      tab name="dev" {
        pane split_direction="vertical" {
          pane size="60%" {
            command "nvim"
          }
          pane size="40%" {
            // Terminal for running commands
          }
        }
      }
    }
  '';

  # Zellij layout for Neovim + Codex CLI development
  home.file.".config/zellij/layouts/codex-dev.kdl".text = ''
    layout {
      default_tab_template {
        pane size=1 borderless=true {
          plugin location="zellij:tab-bar"
        }
        children
        pane size=2 borderless=true {
          plugin location="zellij:status-bar"
        }
      }

      tab name="dev" {
        pane split_direction="vertical" {
          pane size="55%" {
            command "nvim"
          }
          pane size="45%" split_direction="horizontal" {
            pane size="70%" {
              command "codex"
            }
            pane size="30%" {
              // Terminal for running commands
            }
          }
        }
      }
    }
  '';

  # Shell alias for quick launch
  home.shellAliases = {
    kdev = "zellij --layout kiro-dev";
    vdev = "zellij --layout vim-dev";
    cdev = "zellij --layout codex-dev";
  };
}
