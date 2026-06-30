{ config, pkgs, lib, ... }:
let
  username = config.homefree.docker-io-auth.username;
  passwordFile = config.homefree.docker-io-auth.secrets.password;
in
{
  system.activationScripts.podmanAuth = if config.homefree.docker-io-auth.enable == true then ''
    mkdir -p /root/.docker
    PASSWORD=$(cat ${passwordFile})
    ENCODED=$(echo -n "${username}:$PASSWORD" | ${pkgs.coreutils}/bin/base64)
    cat >/root/.docker/config.json << EOF
    {
      "auths": {
        "docker.io": {
          "auth": "$ENCODED"
        }
      }
    }
    EOF
    chmod 600 /root/.docker/config.json
    mkdir -p /var/lib/containers
    cp /root/.docker/config.json /var/lib/containers/auth.json
    chmod 600 /var/lib/containers/auth.json
  '' else "";

  virtualisation = {
    podman = {
      enable = true;

      # Create a `docker` alias for podman, to use it as a drop-in replacement
      dockerCompat = true;
      dockerSocket.enable = true;

      autoPrune.enable = true;

      defaultNetwork.settings = {
        # Required for containers under podman-compose to be able to talk to each other.
        dns_enabled = true;
        ipv6_enabled = true;
        # subnet = "10.88.0.0/16";
        subnets = [
          {
            subnet = "10.88.0.0/16";
            gateway = "10.88.0.1";
          }
          {
            subnet = "fd00::/64";
            gateway = "fd00::1";
          }
        ];
      };
    };
  };

  ## Make the weekly autoPrune reclaim disk WITHOUT deleting containers or
  ## networks. The stock virtualisation.podman.autoPrune runs
  ## `podman system prune -f`, which removes ALL stopped containers (plus
  ## unused networks). That is data loss for any container spawned through
  ## the podman socket OUTSIDE Nix/systemd — specifically Project NOMAD's
  ## content services (nomad_kiwix_server, nomad_kolibri, nomad_cyberchef,
  ## nomad_flatnotes). Those are legitimately Exited after a reboot (the
  ## reboot wrapper stops them; nomad-content-autostart restarts them), and
  ## with Persistent=true the missed weekly timer fires right at boot —
  ## before autostart has run — so the prune kept catching them stopped and
  ## DELETING them: Caddy 502 → the NOMAD tile vanishes (Command Center
  ## polls the socket and marks the service uninstalled) → must reinstall,
  ## which then fails on the orphaned storage layer the interrupted prune
  ## leaves behind. Nix-managed containers are `podman rm -f`'d and
  ## recreated on every start (see the oci-containers ExecStartPre), so they
  ## never need container-pruning here — only dangling images and build
  ## cache actually accumulate, and those are what we still reclaim.
  systemd.services.podman-prune.serviceConfig.ExecStart = lib.mkForce
    "${pkgs.writeShellScript "podman-safe-prune" ''
      set -u
      ${pkgs.podman}/bin/podman image prune -f || true
      ${pkgs.podman}/bin/podman builder prune -f || true
    ''}";
}
