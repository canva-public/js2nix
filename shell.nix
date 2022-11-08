{ nixpkgs ?  import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/13e0d337037b3f59eccbbdf3bc1fe7b1e55c93fd.tar.gz") { } }:

let
  js2nix = nixpkgs.callPackage ./default.nix { };
  tree = js2nix.load ./yarn.lock {
    overlays = [
      (self: super: {
        "babel-jest@27.0.2" = super."babel-jest@27.0.2".override
          # Fix peer dependencies
          (x: { modules = x.modules ++ [ (self."@babel/core@7.14.3") ]; });
      })
    ];
  };

  devNodeModules = js2nix.makeNodeModules ./package.json {
    name = "dev";
    inherit tree;
    prefix = "/lib/node_modules";
    exposeBin = true;
  };

  prodNodeModules = js2nix.makeNodeModules ./package.json {
    name = "prod";
    inherit tree;
    sections = [ "dependencies" ];
  };

in nixpkgs.mkShell {
  # Give the nix-build access to resulting artifact directly with an a standart folder 
  # structure instead of the structure that would be picked up by nodejs pachage setup-hook.
  # To create a folder type:
  #   nix-build -o node_modules -A devNodeModules ./shell.nix
  devNodeModules = devNodeModules.override { prefix = ""; };
  prodNodeModules = prodNodeModules;
  buildInputs = [
    devNodeModules
    nixpkgs.nodejs
    js2nix.bin
    js2nix.proxy
    js2nix.node-gyp
  ];
}
