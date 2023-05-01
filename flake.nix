{
  description = "A js2nix flake";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=13e0d337037b3f59eccbbdf3bc1fe7b1e55c93fd";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    rec {
      packages = forAllSystems (system:
        let
          pkgs' = nixpkgs.legacyPackages.${system};
          js2nix = pkgs'.callPackage ./. { };
        in
        {
          default = js2nix;
          js2nix = js2nix.bin;
          inherit (js2nix) proxy node-gyp;
        });

      devShells = forAllSystems (system:
        let
          pkgs' = nixpkgs.legacyPackages.${system};
          flakePkgs = packages.${system};
          env = flakePkgs.default {
            package-json = ./package.json;
            yarn-lock = ./yarn.lock;
          };
        in
        {
          default = pkgs'.mkShellNoCC {
            passthru.env = env;
            packages = with pkgs'; [
              (env.nodeModules.override { prefix = "/lib/node_modules"; })
              nodejs
              flakePkgs.js2nix
              flakePkgs.node-gyp
              flakePkgs.proxy
            ];
          };
        });
    };
}
