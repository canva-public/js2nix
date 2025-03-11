{ pkgs ? (
    let
      lock = builtins.fromJSON (builtins.readFile ./flake.lock);
      source = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${lock.nodes.nixpkgs.locked.rev}.tar.gz";
    in
    import source { }
  )
}:

let
  js2nix = pkgs.callPackage ./. { };
  env = js2nix {
    package-json = ./package.json;
    yarn-lock = ./yarn.lock;
  };
in
env.nodeModules
