{ lib }:

let
  # Left-side powerline helper that generates left-pointing arrows and CSS
  mkPowerline = modules: colors:
    let
      moduleCount = builtins.length modules;
      
      # Generate arrow modules
      arrows = lib.genAttrs 
        (map (i: "custom/arrow${toString i}") (lib.range 0 (moduleCount - 1)))
        (name: {
          format = "";
          tooltip = false;
        });
      
      # Generate module order with arrows interspersed
      moduleOrder = lib.flatten (lib.imap0 (i: module:
        (lib.optional (i == 0) "custom/arrow0") ++ [ module ] ++ (lib.optional (i < moduleCount - 1) "custom/arrow${toString (i + 1)}")
      ) modules);
      
      # Generate CSS for arrows
      arrowCSS = lib.concatStringsSep "\n" ([
        ''
          #custom-arrow0 {
            font-size: 11pt;
            color: ${builtins.elemAt colors 0};
            background: transparent;
          }
        ''
      ] ++ (lib.imap0 (i: module:
        if i < moduleCount - 1 then ''
          #custom-arrow${toString (i + 1)} {
            font-size: 11pt;
            color: ${builtins.elemAt colors (i + 1)};
            background: ${builtins.elemAt colors i};
          }
        '' else ""
      ) modules));
      
    in {
      inherit arrows moduleOrder arrowCSS;
    };

  # Right-side powerline helper that generates right-pointing arrows and CSS
  mkRightPowerline = modules: colors:
    let
      moduleCount = builtins.length modules;
      
      # Generate arrow modules (including right arrow for last module)
      arrows = lib.genAttrs 
        (map (i: "custom/rarrow${toString i}") (lib.range 0 (moduleCount - 1)))
        (name: {
          format = "";
          tooltip = false;
        });
      
      # Generate module order with arrows interspersed
      moduleOrder = lib.flatten (lib.imap0 (i: module:
        [ module ] ++ (lib.optional (i < moduleCount - 1) "custom/rarrow${toString i}") ++ (lib.optional (i == moduleCount - 1) "custom/rarrow${toString i}")
      ) modules);
      
      # Generate CSS for arrows
      arrowCSS = lib.concatStringsSep "\n" ((lib.imap0 (i: module:
        if i < moduleCount - 1 then ''
          #custom-rarrow${toString i} {
            font-size: 11pt;
            color: ${builtins.elemAt colors i};
            background: ${builtins.elemAt colors (i + 1)};
          }
        '' else ""
      ) modules) ++ [
        # Right arrow for last module
        ''
          #custom-rarrow${toString (moduleCount - 1)} {
            font-size: 11pt;
            color: ${builtins.elemAt colors (moduleCount - 1)};
            background: transparent;
          }
        ''
      ]);
      
    in {
      inherit arrows moduleOrder arrowCSS;
    };
    
in {
  inherit mkPowerline mkRightPowerline;
}