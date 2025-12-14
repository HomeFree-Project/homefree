final: prev:
{
  ddclient = prev.ddclient.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or []) ++ [
      ./ddclient-hetzner-cloud.patch
    ];
  });
}
