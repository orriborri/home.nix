{ pkgs, lib, ... }:

let
  # Script to focus/move existing foot window to current workspace, or launch new one
  focus-terminal = pkgs.writeShellScriptBin "gnome-focus-terminal" ''
    # Find an existing foot window
    FOOT_WIN=$(${pkgs.xdotool}/bin/xdotool search --class foot | head -1)

    if [ -n "$FOOT_WIN" ]; then
      # Get current desktop
      CURRENT_WS=$(${pkgs.xdotool}/bin/xdotool get-desktop)
      # Move the window to current workspace and focus it
      ${pkgs.xdotool}/bin/xdotool set-desktop-for-window "$FOOT_WIN" "$CURRENT_WS"
      ${pkgs.xdotool}/bin/xdotool windowactivate "$FOOT_WIN"
    else
      foot &
    fi
  '';
in
{
  home.packages = [ pkgs.xdotool ];

  dconf.settings = {
    # Custom keybindings
    "org/gnome/settings-daemon/plugins/media-keys" = {
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
      ];
    };

    # Super+Return → focus/move existing terminal to current workspace
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      name = "Focus Terminal";
      command = "${focus-terminal}/bin/gnome-focus-terminal";
      binding = "<Super>Return";
    };

    # Ctrl+Super+Return → always open new terminal
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
      name = "New Terminal";
      command = "foot";
      binding = "<Ctrl><Super>Return";
    };

    # Disable default Super+N app launching (conflicts with workspace switching)
    "org/gnome/shell/keybindings" = {
      toggle-overview = [ "<Super>d" ];
      show-screenshot-ui = [ "<Super>p" ];
      switch-to-application-1 = [];
      switch-to-application-2 = [];
      switch-to-application-3 = [];
      switch-to-application-4 = [];
      switch-to-application-5 = [];
      switch-to-application-6 = [];
      switch-to-application-7 = [];
      switch-to-application-8 = [];
      switch-to-application-9 = [];
    };

    # Disable default Super overlay so it doesn't conflict
    "org/gnome/mutter" = {
      overlay-key = "";
      dynamic-workspaces = false;
      workspaces-only-on-primary = true;
    };

    # App switcher scoped to current workspace
    "org/gnome/shell/app-switcher" = {
      current-workspace-only = true;
    };

    # 9 static workspaces
    "org/gnome/desktop/wm/preferences" = {
      num-workspaces = 9;
    };

    # Keyboard layout (Finnish)
    "org/gnome/desktop/input-sources" = {
      sources = [ (lib.hm.gvariant.mkTuple [ "xkb" "fi" ]) ];
    };

    # Window tiling
    "org/gnome/mutter/keybindings" = {
      toggle-tiled-left = [ "<Super>Left" ];
      toggle-tiled-right = [ "<Super>Right" ];
    };

    # Workspace switching and window management
    "org/gnome/desktop/wm/keybindings" = {
      close = [ "<Shift><Super>q" ];
      switch-to-workspace-1 = [ "<Super>1" ];
      switch-to-workspace-2 = [ "<Super>2" ];
      switch-to-workspace-3 = [ "<Super>3" ];
      switch-to-workspace-4 = [ "<Super>4" ];
      switch-to-workspace-5 = [ "<Super>5" ];
      switch-to-workspace-6 = [ "<Super>6" ];
      switch-to-workspace-7 = [ "<Super>7" ];
      switch-to-workspace-8 = [ "<Super>8" ];
      switch-to-workspace-9 = [ "<Super>9" ];
    };
  };
}
