{ mkDerivation, aeson, aeson-pretty, base, bytestring, data-fix
, deepseq, directory, exceptions, filepath, hashable, hnix
, megaparsec, mtl, optparse-applicative, prettyprinter, process
, regex-tdfa, stdenv, string-qq, text, unordered-containers
}:
mkDerivation {
  pname = "nix-wrangle";
  version = "0.0.0";
  src = ./..;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson aeson-pretty base bytestring data-fix deepseq directory
    exceptions filepath hashable hnix megaparsec mtl
    optparse-applicative prettyprinter process regex-tdfa string-qq
    text unordered-containers
  ];
  license = "unknown";
  hydraPlatforms = stdenv.lib.platforms.none;
}
