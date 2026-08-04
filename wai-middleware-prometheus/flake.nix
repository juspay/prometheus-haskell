{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    nixpkgs.url = "github:nixos/nixpkgs/89c2b2330e733d6cdb5eae7b899326930c2c0648";
    systems.url = "github:nix-systems/default";
    unix-memory =
      {
        type = "git";
        url = "https://github.com/juspay/hs-unix-memory.git";
        # GHC 9.8 support lives in PR #1; juspay master does not have it yet.
        # Switch to ref = "master" once that PR is merged.
        ref = "refs/pull/1/head";
        rev = "bad0e19ea702d26489c6e76975e54601dd8ae991";
        flake = false;
      };
    prometheus-client = {
      url = "path:../prometheus-client";
      flake = false;
    };
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake { inherit inputs; } {
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
            unix-memory.source=inputs.unix-memory;
            prometheus-client.source=inputs.prometheus-client;
          };
          settings = {
          };
          devShell = {
            tools = hp: {
              haskell-language-server = null;
            };
          };
        };
        packages.default = self'.packages.wai-middleware-prometheus;
      };
    };
}