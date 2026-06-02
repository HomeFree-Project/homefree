{ stdenv, fetchFromGitHub, lib }:
stdenv.mkDerivation {
  pname = "home-assistant-custom-component-opensprinkler";
  version = "1.3.7";

  src = fetchFromGitHub {
    owner = "vinteo";
    repo = "hass-opensprinkler";
    rev = "v1.3.7";
    sha256 = "1ywdcdiz62ghwb3r7dh4pdz6g9i70iv4wp6cncz2w3cd68j8rx50";
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/custom_components
    cp -r custom_components/opensprinkler $out/custom_components/opensprinkler
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenSprinkler integration for Home Assistant";
    homepage = "https://github.com/vinteo/hass-opensprinkler";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
