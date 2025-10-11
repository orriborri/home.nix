{ lib }:

let
  # Generate powerline arrow between two colors
  mkArrow = name: fromColor: toColor: {
    "custom/arrow-${name}" = {
      format = "";
      tooltip = false;
    };
  };

  # Generate powerline module with background color
  mkModule = name: color: textColor: content: {
    "custom/${name}" = content // {
      format = content.format or "{}";
    };
  };

  # Generate complete powerline section with arrows
  mkPowerlineSection = modules: 
    let
      moduleNames = builtins.attrNames modules;
      colors = builtins.map (name: modules.${name}.color) moduleNames;
      
      # Generate arrows between modules
      arrows = lib.lists.imap0 (i: name: 
        if i < (builtins.length moduleNames - 1) then
          let
            currentColor = modules.${name}.color;
            nextColor = modules.${builtins.elemAt moduleNames (i + 1)}.color;
          in mkArrow "${name}-${builtins.elemAt moduleNames (i + 1)}" currentColor nextColor
        else {}
      ) moduleNames;
      
      # Combine modules and arrows
      allModules = lib.attrsets.mergeAttrsList (
        lib.lists.flatten (lib.lists.imap0 (i: name:
          [ (mkModule name modules.${name}.color modules.${name}.textColor modules.${name}.config) ] ++
          (if i < (builtins.length moduleNames - 1) then [ (builtins.elemAt arrows i) ] else [])
        ) moduleNames)
      );
      
    in {
      modules = allModules;
      moduleOrder = lib.lists.flatten (lib.lists.imap0 (i: name:
        [ "custom/${name}" ] ++
        (if i < (builtins.length moduleNames - 1) then [ "custom/arrow-${name}-${builtins.elemAt moduleNames (i + 1)}" ] else [])
      ) moduleNames);
    };

in {
  inherit mkArrow mkModule mkPowerlineSection;
  
  # Example usage:
  # powerlineSection = mkPowerlineSection {
  #   kanshi = {
  #     color = "rgba(40, 40, 40, 0.8784313725)";
  #     textColor = "@white";
  #     config = {
  #       exec = "echo '🖥️'";
  #       on-click = "...";
  #     };
  #   };
  #   power-profile = {
  #     color = "@power";
  #     textColor = "@black";
  #     config = {
  #       exec = "...";
  #     };
  #   };
  # };
}