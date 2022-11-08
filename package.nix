let
  shell = import ./shell.nix { };
  inherit (shell) devNodeModules prodNodeModules;
in devNodeModules // {
  # Make these closures available to pick up by passing --production flag
  prod = prodNodeModules;
}
