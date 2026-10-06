{ pkgs, llm-agents, ... }:
{
  home.packages = [ llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop ];
}
