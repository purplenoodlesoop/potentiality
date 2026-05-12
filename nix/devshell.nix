{ pkgs, ... }:
{
  devShells.default = pkgs.mkShell {
    name = "potentiality";
    buildInputs = with pkgs; [
      haskellPackages.ghc
      cabal-install
      haskellPackages.haskell-language-server
      haskellPackages.fourmolu
      haskellPackages.hlint
      zlib
      pkg-config
    ];
    shellHook = ''
      echo "potentiality dev shell"
      echo "  ghc $(${pkgs.haskellPackages.ghc}/bin/ghc --numeric-version)"
      echo "  cabal $(${pkgs.cabal-install}/bin/cabal --numeric-version)"
    '';
  };
}
