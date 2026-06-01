{ stdenv, fetchFromGitHub, lib }:
stdenv.mkDerivation {
  pname = "home-assistant-custom-component-redfin";
  version = "1.1.4";

  src = fetchFromGitHub {
    owner = "dreed47";
    repo = "redfin";
    rev = "v1.1.4";
    sha256 = "1hysyw782ghni97n9sibd8b9l59pxdr49gwpm60674b24kd9jqa9";
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/custom_components
    cp -r custom_components/redfin $out/custom_components/redfin
    runHook postInstall
  '';

  meta = with lib; {
    description = "Redfin home value integration for Home Assistant";
    homepage = "https://github.com/dreed47/redfin";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
