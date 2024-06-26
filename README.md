# home.nix
Home Manager configuration files

## Installation

- Install the [Nix package manager](https://nixos.org/download.html#nix-quick-install)
- Clone this repo to `~/.config/home-manager` by running:

  ```
  nix-shell -p git --command "git clone https://github.com/orriborri/home.nix.git $HOME/.config/home-manager"
  ```

- Edit `home.nix`, change at least `home.homeDirectory` to match yours.

- Install [Home Manager](https://github.com/nix-community/home-manager#installation)
- Run `nu` to try the config in action. Make your terminal run `tmux
  new-session -A -s main` to automatically open nushell in a tmux session.

  - For example (WSL): "Command line" in Windows Terminal profile settings:
    
    ```
    wsl.exe -d Ubuntu -e bash -lc "tmux new-session -A -s main"
    ```
