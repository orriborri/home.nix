{ pkgs, ... }:

{
  enable = true;
  settings = {
    os.editCommand = "zed";
    os.editCommandTemplate = "{{editor}} {{filename}}:{{line}}";
  };
}
