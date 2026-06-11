# Wave 2b: behavioural VM smoke. Boots the synthetic-instance appliance (the
# Wave 2a fixture, through the real loader) in a hermetic nixosTest and asserts
# the recovery surface comes up: caddy serves the admin SPA and the admin-api
# blue/green host service is active.
#
# Hermetic constraints handled:
#   - homefree.development = true  -> caddy uses local_certs (no external ACME,
#     which would hang with no network in the test sandbox).
#   - homefree.network.router.enable = false -> no eth1/nftables/DHCP wiring
#     (the test VM only has the framework's eth0).
#   - Container apps (zitadel/oauth2-proxy/etc.) cannot pull images with no
#     network, so we test the HOST services (caddy, admin-api) only and the
#     SSO gate's open-fail (pre-provisioning) path. The fixture enables just
#     admin + landing-page.
#
# Exposed as a package (run: `nix build .#vm-admin-boot`) rather than a check,
# to keep the offline `nix flake check` fast. Needs /dev/kvm.
{ self, inputs, ... }:
{
  perSystem = { system, lib, ... }:
    let
      homefree-inputs =
        (builtins.removeAttrs inputs [ "flake-parts" "import-tree" ]) // { inherit self; };
      sampleJson = builtins.fromJSON
        (builtins.readFile (self + "/tests/fixtures/sample-homefree-config.json"));
      pkgsUnstable = inputs.nixpkgs-unstable.legacyPackages.${system};
    in
    {
      packages.vm-admin-boot = pkgsUnstable.testers.runNixOSTest {
        name = "homefree-admin-boot";

        # Let each node instantiate its OWN nixpkgs from its modules'
        # nixpkgs.config (profiles/common.nix sets allowUnfree; apps set
        # packageOverrides). The framework default injects a read-only pkgs,
        # which those module-level nixpkgs.config definitions then conflict
        # with. This mirrors how the real lib.nixosSystem configs build.
        # mkForce to win over the framework's default node.pkgs.
        node.pkgs = lib.mkForce null;

        # specialArgs for every test node — must match what the real
        # nixosConfigurations pass (homefree-inputs + system), or apps/headscale
        # et al. recurse trying to resolve homefree-inputs via _module.args. The
        # loader additionally needs the parsed JSON + instance dir.
        node.specialArgs = {
          inherit system homefree-inputs;
          homefreeConfigJson = sampleJson;
          homefreeInstanceDir = self + "/tests/fixtures";
        };

        nodes.machine = { lib, ... }: {
          imports = [
            self.nixosModules.homefree
            self.nixosModules.homefree-config-loader
          ];
          # node.pkgs = null means each node builds its own nixpkgs; it must
          # know the platform.
          nixpkgs.hostPlatform = system;
          # Hermetic-boot overrides (see header).
          homefree.development = lib.mkForce true;
          homefree.network.router.enable = lib.mkForce false;
          # Router is off (it would fight the test framework's networking), but
          # abuse-blocking still asserts nftables. Enable it to satisfy the
          # assertion; its fail2ban jails are inert here and don't gate boot.
          networking.nftables.enable = lib.mkForce true;
          virtualisation.memorySize = lib.mkForce 4096;
          virtualisation.diskSize = lib.mkForce 8192;
          virtualisation.cores = lib.mkForce 2;
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")

          # caddy (host service) is the reverse proxy / static file server.
          machine.wait_for_unit("caddy.service")

          # admin-api runs as a host blue/green systemd service (NOT a container),
          # so it comes up without an image pull.
          machine.wait_until_succeeds(
              "systemctl is-active admin-api-blue.service "
              "|| systemctl is-active admin-api-green.service",
              timeout=180,
          )

          # The admin SPA (open-fail before SSO provisioning) is served on the
          # admin subdomain (https, local cert) and the bare LAN-IP http vhost;
          # the apex / localDomain hosts serve the landing page instead. Accept
          # the SPA shell (#app) on any of admin's canonical hosts.
          served = ""
          for cmd in [
              "curl -fsSk -H 'Host: admin.homefree.example' https://localhost/",
              "curl -fsS  -H 'Host: 10.0.0.1' http://localhost/",
              "curl -fsSk -H 'Host: home.homefree.example' https://localhost/",
          ]:
              served = machine.succeed(cmd + " 2>/dev/null || true")
              if 'id="app"' in served:
                  break
          assert 'id="app"' in served, "admin SPA (id=app) not served on any admin host"

          # Diagnostic: surface any failed units (non-fatal).
          print(machine.succeed("systemctl --failed --no-legend || true"))
        '';
      };
    };
}
