{ stdenv, fetchFromGitHub, lib }:
stdenv.mkDerivation {
  pname = "home-assistant-custom-component-tesla_custom";
  version = "3.24.1";

  src = fetchFromGitHub {
    owner = "alandtse";
    repo = "tesla";
    rev = "v3.24.1";
    sha256 = "07qhzfqikxci2bf0pqfg8ywbck0lmxjr05zza3hk6grj0cdrz850";
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/custom_components
    cp -r custom_components/tesla_custom $out/custom_components/tesla_custom
    runHook postInstall
  '';

  meta = with lib; {
    description = "Tesla Custom Integration for Home Assistant";
    homepage = "https://github.com/alandtse/tesla";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
