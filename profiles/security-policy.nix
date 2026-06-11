# HomeFree host-security policy (Layer 2 — product-specific).
#
# Holds the host-security knobs gated on homefree.system.* toggles. Imported
# ONLY by the homefree box (configuration.nix), NOT by the shared
# profiles/common.nix — that base profile is also used by lan-client, which
# does not declare the homefree.* options, so it must stay free of homefree.*
# references. This is the Layer-0-shouldn't-reach-Layer-2 extraction the test
# net flagged; the move is behaviour-preserving (drvPath-guarded).
{ config, lib, ... }:
{
  ## Wheel-group NOPASSWD: ALL, gated on homefree.system.wheel-passwordless
  ## (default true — historical; useful for debugging and unattended
  ## automation). When false, the rule is omitted and wheel members re-enter
  ## their password on `sudo`. See module.nix for the option declaration and
  ## docs/agent-notes/security-audit-phase-5.md.
  security.sudo.extraRules = lib.optionals config.homefree.system.wheel-passwordless [
    {
      groups = [ "wheel" ];
      commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
    }
  ];

  ## SSH: PasswordAuthentication + KbdInteractiveAuthentication gated behind
  ## homefree.system.ssh-key-only (default false — preserves historical
  ## password-login, mitigated by the WAN firewall + Phase 4 sshd fail2ban
  ## jail). When true, only public-key auth is accepted — confirm the admin
  ## user has a working SSH key first or remote access is lost. The daemon
  ## itself (services.openssh.enable) stays in the shared common.nix.
  services.openssh.settings = lib.mkIf config.homefree.system.ssh-key-only {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
}
