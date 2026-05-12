{ pkgs, ... }:
let
  src = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        name = baseNameOf (toString path);
      in
      !(builtins.elem name [
        "dist-newstyle"
        "dist"
        "result"
        ".direnv"
        ".git"
      ]);
  };

  potentiality = pkgs.haskellPackages.callCabal2nix "potentiality" src { };
in
{
  packages.default = potentiality;
  packages.potentiality = potentiality;

  apps.default = {
    type = "app";
    program = "${potentiality}/bin/pot";
  };
}
