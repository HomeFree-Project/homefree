## auditd — kernel-level audit trail for sensitive paths.
##
## Phase 5 M1 from docs/agent-notes/security-audit-phase-5.md.
##
## Before this module landed, HomeFree had no forensic record of who
## modified `/etc/nixos`, `/etc/sudoers`, `/etc/ssh/`, or anything
## under `/var/lib/homefree-secrets/`. Post-incident, there was no
## audit trail to attribute a change — a compromised admin account
## could rotate keys, edit hba, or exfiltrate secrets and leave no
## per-syscall record.
##
## NixOS's `security.audit` enables the kernel auditd subsystem and
## starts userland `auditd` which drains the kernel ring buffer into
## /var/log/audit/audit.log. systemd-journald also picks up the
## events (the kernel emits them to the audit netlink socket which
## journald subscribes to via `KAuditLogged`), so they show up in
## `journalctl _TRANSPORT=audit`.
##
## Rules below use the `-w <path> -p wa -k <name>` form, which means:
##   -w <path>   watch this path (and everything under it if dir)
##   -p wa       audit writes (w) and attribute changes (a)
##   -k <name>   tag matching events with this key for grep
##
## Read access is NOT audited — that would generate a flood of events
## (every `cat /etc/sudoers` from a config tool would log). Writes
## and attribute changes are the integrity-relevant signal.
##
## To query: `sudo ausearch -k homefree-secrets` or
## `sudo journalctl _TRANSPORT=audit -g hf-`.
##
## Disk usage: NixOS defaults to ~500 MB rotated audit logs. Lower
## via `security.auditd.enable` knobs if disk is tight; default is
## fine for a HomeFree box.

{ config, lib, ... }:

{
  security.audit = {
    enable = true;
    ## Format: list of audit rules in audit.rules(7) syntax.
    rules = [
      ## /etc/nixos — the entire instance config tree. Every
      ## generated module/secret/option file lives here; any write
      ## is a config change.
      "-w /etc/nixos -p wa -k hf-etc-nixos"

      ## /etc/sudoers + sudoers.d — privilege-escalation grants.
      "-w /etc/sudoers -p wa -k hf-sudoers"
      "-w /etc/sudoers.d -p wa -k hf-sudoers"

      ## SSH server config + host keys. The host keys are also the
      ## age-recipient key used by sops to decrypt secrets.yaml, so
      ## a tamper here would compromise the secret store too.
      "-w /etc/ssh -p wa -k hf-ssh"

      ## Runtime secrets dir — anchored per-service passwords,
      ## tokens, OIDC client secrets, the masterkey. Every file in
      ## here is sensitive.
      "-w /var/lib/homefree-secrets -p wa -k hf-secrets"

      ## Encrypted secrets store (sops + age). secrets.yaml is the
      ## backed-up source-of-truth for every anchored secret. The
      ## /etc/nixos watch above already covers this (sops file lives
      ## under /etc/nixos/secrets/), but keep an explicit tag so
      ## ausearch can filter secret-store changes specifically.
      "-w /etc/nixos/secrets -p wa -k hf-sops"
    ];
  };

  ## Userland auditd daemon. Without this, kernel events stack up in
  ## the ring buffer until it overflows (rate-limited; events get
  ## dropped). The daemon drains the buffer to /var/log/audit/.
  security.auditd.enable = true;
}
