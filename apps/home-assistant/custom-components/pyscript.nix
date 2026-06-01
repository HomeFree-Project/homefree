{ stdenv, fetchFromGitHub, lib }:
stdenv.mkDerivation {
  pname = "home-assistant-custom-component-pyscript";
  version = "2.0.1";

  src = fetchFromGitHub {
    owner = "custom-components";
    repo = "pyscript";
    rev = "2.0.1";
    sha256 = "0wzfg9bbs7p02amhc5axc3rahsd9xx22iimpqn0f35kl5d118d76";
  };

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/custom_components
    cp -r custom_components/pyscript $out/custom_components/pyscript
    runHook postInstall
  '';

  meta = with lib; {
    description = "Pyscript: Python scripting for Home Assistant automations";
    homepage = "https://github.com/custom-components/pyscript";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
