# Materialise the instance-level AGENTS.md / CLAUDE.md into /etc/nixos on
# every `nixos-rebuild switch`.
#
# /etc/nixos is a box's INSTANCE STATE, not source — operators and AI
# agents must not hand-edit it or drop generic .nix modules there (rule 12
# in the shared repo's AGENTS.md). These two docs tell whoever opens the
# directory how to extend HomeFree (the Custom Flake mechanism on the
# Plugins page) and how to change HomeFree itself (a local clone pointed at
# by "Alternate HomeFree Repository" on the Source Code page).
#
# Why an activation script (not environment.etc, not the installer):
#   - environment.etc only manages /etc/* symlinks; /etc/nixos is a real
#     mutable directory it cannot target.
#   - the installer writes /etc/nixos ONCE; we want the docs refreshed on
#     every rebuild so edits to the canonical copy in the shared repo
#     propagate to every box — and a box predating this code gains them on
#     its next switch (the rule-11 idempotent on-activation migration).
#   - an activation script runs on EVERY switch (admin Apply AND a bare
#     `nixos-rebuild switch`), as root, so the write always lands.
#
# Both files are in the managed manifest
# (web-platform/backend/services/instance_layout.py), so the divergence
# detector never flags them. Overwriting them every switch is intentional:
# the build OWNS these docs (auto-restore of managed structure).
{ pkgs, ... }:
let
  agentsMd = ./instance-managed-docs/AGENTS.md;
  instanceDir = "/etc/nixos";
in
{
  system.activationScripts.homefree-instance-docs = ''
    if [ -d ${instanceDir} ]; then
      ${pkgs.coreutils}/bin/install -m 0644 ${agentsMd} ${instanceDir}/AGENTS.md
      # CLAUDE.md just re-exports AGENTS.md (Claude Code @-import syntax).
      printf '@AGENTS.md\n' > ${instanceDir}/CLAUDE.md
      ${pkgs.coreutils}/bin/chmod 0644 ${instanceDir}/CLAUDE.md
    fi
  '';
}
