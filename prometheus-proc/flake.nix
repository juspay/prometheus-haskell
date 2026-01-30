{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    nixpkgs.url = "github:nixos/nixpkgs/89c2b2330e733d6cdb5eae7b899326930c2c0648";
    systems.url = "github:nix-systems/default";
    unix-memory =
      {
        url = "https://github.com/infinitumkiran/hs-unix-memory.git";
        rev= "bad0e19ea702d26489c6e76975e54601dd8ae991";
        ref = "ghc984";
        flake = false;
      };
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake { inputs = inputs // { inherit (inputs) nixpkgs nixpkgs-latest; }; } {
      systems = import inputs.systems;
      imports = [inputs.haskell-flake.flakeModule];

      perSystem = { self', pkgs, ... }: {
        haskellProjects.default = {
          projectFlakeName = "classyplate";
          basePackages = pkgs.haskell.packages.ghc98;
          packages = {
            unix-memory.source=inputs.unix-memory;  
          };
          settings = {
          };
                  };
      };
    };
}