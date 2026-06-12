{ pkgs, ... }:

{
  enable = true;
  settings = {
    window = {
      opacity = 0.95;
      decorations = "None";
    };
    
    font = {
      normal = {
        family = "JetBrainsMono Nerd Font";
      };
      size = 11;
    };

    colors = {
      primary = {
        background = "#0b0e14";
        foreground = "#b3b1ad";
      };
    };
  };
}
