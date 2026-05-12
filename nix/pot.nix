# Hand-written cabal2nix-style derivation. Regenerate with:
#   nix run nixpkgs#cabal2nix -- . > nix/pot.nix
# when cabal2nix is available in your nixpkgs (it currently fails to build
# transitively through apr-util on this revision; tracked separately).
{ mkDerivation
, aeson
, aeson-pretty
, base
, bytestring
, exceptions
, filepath
, lib
, optparse-applicative
, path
, path-io
, random
, text
, time
, typed-process
, yaml
}:
mkDerivation {
  pname = "potentiality";
  version = "0.1.0.0";
  src = lib.cleanSource ./..;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson
    aeson-pretty
    base
    bytestring
    exceptions
    filepath
    optparse-applicative
    path
    path-io
    random
    text
    time
    typed-process
    yaml
  ];
  executableHaskellDepends = [
    base
  ];
  homepage = "https://github.com/purplenoodlesoop/potentiality";
  description = "Haskell agent runner over a Markdown vault.";
  license = lib.licenses.mit;
  mainProgram = "pot";
}
