{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    nixpkgs.url = "github:nixos/nixpkgs/89c2b2330e733d6cdb5eae7b899326930c2c0648";
    systems.url = "github:nix-systems/default";
    unix-memory.url = "path:/home/kiransai-abhishek/repos/hs-unix-memory";
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

      perSystem = {
        self',
        pkgs,
        lib,
        config,
        ...
      }: {
        haskellProjects.default = {
          basePackages = pkgs.haskell.packages.ghc98;
          packages = {
            record-dot-preprocessor.source="0.2.17";
            servant.source="0.20.2";
            unix-memory.source=inputs.unix-memory;  
          };
          settings = {
          };
          devShell = {
            tools = hp: {
              haskell-language-server = null;
            };
          };
        };
        packages.default =  self'.packages.ghc-hasfield-plugin;
      };
    };
}