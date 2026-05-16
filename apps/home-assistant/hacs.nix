## Home Assistant Community Store (HACS) custom integration.
## Once symlinked into /config/custom_components/hacs/, users add it
## via Settings → Devices → Add Integration → HACS, then use the HACS
## tab to install and update community integrations and frontend cards
## from inside the HA UI. Installed components land in
## /config/custom_components/ and /config/www/community/ at runtime —
## non-declarative state, but that's the point of HACS.
##
## Source: the GitHub *release* asset hacs.zip, not the source tarball.
## The release zip bundles the hacs_frontend Python module (web assets);
## the source tree does NOT, so HA's loader would fail on
## `from custom_components.hacs.hacs_frontend import ...`.
{ stdenv, fetchurl, lib, unzip }:
stdenv.mkDerivation {
  pname = "home-assistant-custom-component-hacs";
  version = "2.0.5";

  src = fetchurl {
    url = "https://github.com/hacs/integration/releases/download/2.0.5/hacs.zip";
    sha256 = "04zlmn3k0ylq7cdqnhj31anqnsvz6rrdvilcfa1ycf2g9a16pglp";
  };

  nativeBuildInputs = [ unzip ];

  unpackPhase = ''
    runHook preUnpack
    mkdir -p src
    unzip -q $src -d src
    runHook postUnpack
  '';

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/custom_components/hacs
    cp -r src/* $out/custom_components/hacs/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Home Assistant Community Store integration";
    homepage = "https://hacs.xyz";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
