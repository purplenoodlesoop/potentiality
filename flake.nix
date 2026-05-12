{
  description = "Potentiality — Haskell agent runner over a Markdown vault.";

  inputs = {
    core-flake.url = "github:purplenoodlesoop/core-flake";
    nixpkgs.follows = "core-flake/nixpkgs";
    flake-utils.follows = "core-flake/flake-utils";
  };

  outputs =
    { core-flake, ... }:
    core-flake.lib.evalFlake {
      perSystem.imports = [
        ./nix/package.nix
        ./nix/devshell.nix
      ];
    };
}
