final: prev:
{
  ## Use cr3/ddclient PR #876 (https://github.com/ddclient/ddclient/pull/876),
  ## which modernizes the built-in `hetzner` provider to talk to the new Hetzner
  ## Cloud DNS API (api.hetzner.cloud/v1) instead of the legacy
  ## dns.hetzner.com/api/v1 endpoint. Track that PR for a merged release.
  ##
  ## ddclient-apex-fix.patch is a local fix on top of PR #876: the PR computes
  ## the rrset name with `s/\Q.$zone\E$//`, which leaves the full FQDN in
  ## $hostname when the domain equals the zone (the apex). Hetzner needs `@`
  ## for the apex, so without this fix ddclient writes a bogus rrset like
  ## `homefree.host.homefree.host` and the real apex AAAA never gets updated.
  ddclient = prev.ddclient.overrideAttrs (oldAttrs: {
    src = prev.fetchFromGitHub {
      owner = "cr3";
      repo = "ddclient";
      rev = "61d78f51f9e79d88525c445c50d36d9e831b875f";
      hash = "sha256-khnoIsCp/gnF6bBaZHWtTddfmOmvPGhXORfMeK6sv/E=";
    };
    patches = [ ./ddclient-apex-fix.patch ];
  });
}
