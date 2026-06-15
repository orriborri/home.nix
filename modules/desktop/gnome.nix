{ lib, pkgs, ... }:
let
  focusTerminal = pkgs.writeShellScriptBin "gnome-focus-terminal" ''
    # Try to focus existing Alacritty window via GNOME extension D-Bus
    result=$(gdbus call --session \
      --dest org.gnome.Shell \
      --object-path /de/lucaswerkmeister/ActivateWindowByTitle \
      --method de.lucaswerkmeister.ActivateWindowByTitle.ActivateByWmClass "Alacritty" 2>/dev/null)

    if [[ "$result" != *"true"* ]]; then
      /home/orre/.nix-profile/bin/alacritty -e /home/orre/.nix-profile/bin/zellij attach --create main &
    fi
  '';
in
{
  home.packages = [
    pkgs.gnomeExtensions.activate-window-by-title
    pkgs.gnomeExtensions.tiling-shell
  ];

  dconf.settings = {
    # Shell extensions
    "org/gnome/shell" = {
      enabled-extensions = [
        "activate-window-by-title@lucaswerkmeister.de"
        "tilingshell@ferrarodomenico.com"
      ];
    };

    # Input sources
    "org/gnome/desktop/input-sources" = {
      sources = [ (lib.hm.gvariant.mkTuple [ "xkb" "fi" ]) ];
      xkb-options = [ "terminate:ctrl_alt_bksp" ];
    };

    # Interface
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      show-battery-percentage = true;
      toolkit-accessibility = false;
    };

    # Night light
    "org/gnome/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-schedule-automatic = false;
    };

    # Mutter
    "org/gnome/mutter" = {
      dynamic-workspaces = true;
      experimental-features = [ ];
      overlay-key = "";
      workspaces-only-on-primary = true;
    };

    # Window tiling
    "org/gnome/mutter/keybindings" = {
      toggle-tiled-left = [ "<Super>Left" ];
      toggle-tiled-right = [ "<Super>Right" ];
    };

    # Workspaces
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

    # App switcher
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

    # Super+Return → focus existing terminal or launch alacritty+zellij
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      name = "Focus Terminal";
      command = "${focusTerminal}/bin/gnome-focus-terminal";
      binding = "<Super>Return";
    };

    # Ctrl+Super+Return → always open new terminal
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
      name = "New Terminal";
      command = "/home/orre/.nix-profile/bin/alacritty -e /home/orre/.nix-profile/bin/zellij";
      binding = "<Ctrl><Super>Return";
    };

    # Nautilus
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "list-view";
      migrated-gtk-settings = true;
    };

    # File chooser
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
