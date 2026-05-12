{
  description = "Potentiality — Haskell agent runner over a Markdown vault.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    core-flake = {
      url = "github:purplenoodlesoop/core-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { core-flake, ... }:
    with core-flake;
    lib.evalFlake {
      perSystem =
        { pkgs, ... }:
        let
          potentiality = pkgs.callPackage ./nix/potentiality.nix { };
        in
        {
          flake = {
            packages.default = potentiality;
            packages.potentiality = potentiality;
            shell = [
              pkgs.haskellPackages.ghc
              pkgs.cabal-install
              pkgs.haskellPackages.haskell-language-server
              pkgs.haskellPackages.fourmolu
              pkgs.haskellPackages.hlint
              pkgs.zlib
              pkgs.pkg-config
            ];
          };
        };
    };
}
