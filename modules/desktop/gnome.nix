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
    # Input sources
    "org/gnome/desktop/input-sources" = {
      sources = [ (lib.hm.gvariant.mkTuple [ "xkb" "fi" ]) ];
      xkb-options = [ "terminate:ctrl_alt_bksp" ];
    };

    # Interface
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      show-battery-percentage = true;
    };

    # Night light
    "org/gnome/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-schedule-automatic = false;
    };

    # Mutter
    "org/gnome/mutter" = {
      dynamic-workspaces = true;
      overlay-key = "";
      workspaces-only-on-primary = true;
    };

    # Window tiling
    "org/gnome/mutter/keybindings" = {
      toggle-tiled-left = [ "<Super>Left" ];
      toggle-tiled-right = [ "<Super>Right" ];
    };

    # 9 static workspaces
    "org/gnome/desktop/wm/preferences" = {
      num-workspaces = 9;
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

    # Disable default Super+N app launching (conflicts with workspace switching)
    "org/gnome/shell/keybindings" = {
      toggle-overview = [ "<Super>d" ];
      show-screenshot-ui = [ "<Super>p" ];
      switch-to-application-1 = [ ];
      switch-to-application-2 = [ ];
      switch-to-application-3 = [ ];
      switch-to-application-4 = [ ];
      switch-to-application-5 = [ ];
      switch-to-application-6 = [ ];
      switch-to-application-7 = [ ];
      switch-to-application-8 = [ ];
      switch-to-application-9 = [ ];
    };

    # App switcher — NOT scoped to current workspace (matches your setting)
    "org/gnome/shell/app-switcher" = {
      current-workspace-only = false;
    };

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

    # File chooser preferences
    "org/gtk/gtk4/settings/file-chooser" = {
      show-hidden = true;
    };

    "org/gtk/settings/file-chooser" = {
      show-hidden = true;
      sort-column = "modified";
      sort-order = "descending";
    };

    # Break reminders
    "org/gnome/desktop/break-reminders/movement" = {
      duration-seconds = lib.hm.gvariant.mkUint32 300;
      interval-seconds = lib.hm.gvariant.mkUint32 1800;
      play-sound = true;
    };

    "org/gnome/desktop/break-reminders/eyesight" = {
      play-sound = true;
    };
  };
}
