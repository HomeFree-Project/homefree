{ config, lib, ... }:
{
  # Configure sops-nix for secrets management
  sops = {
    # Default file where secrets are stored (encrypted)
    defaultSopsFile = /etc/nixos/secrets/secrets.yaml;

    # Use system SSH host key for decryption
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Don't generate age keys automatically (we use SSH keys)
    age.generateKey = false;

    # Validate secrets on activation
    validateSopsFiles = lib.mkDefault true;

    # Secrets will be decrypted to /run/secrets/<name>
    # with appropriate permissions (mode 0400, owner root by default)
  };

  # Ensure /etc/nixos/secrets directory exists
  system.activationScripts.createSecretsDir = {
    text = ''
      mkdir -p /etc/nixos/secrets
      chmod 700 /etc/nixos/secrets
    '';
  };
}
