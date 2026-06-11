## Cockpit — web-based host system management (cockpit-project.org):
## systemd units, journal, terminal, metrics, accounts, the podman
## container fleet (cockpit-podman plugin, default on), and optionally
## QEMU/KVM virtual machines (cockpit-machines + libvirt, opt-in via
## machines-ui).
##
## Runs NATIVELY on the host via nixpkgs' `services.cockpit` — NOT a
## container, since the host itself is what it manages. cockpit-ws /
## cockpit-tls are upstream socket-activated units running as their own
## instantiated users, and each login session runs as the PAM-
## authenticated user, so no new root daemon is added here.
##
## Auth posture: Cockpit has no OIDC — its login is PAM against host
## accounts. The Caddy SSO gate (admin role required) is the outer
## layer; see the sso block below.
##
## Note: the installer ISO ships its own loopback-only Cockpit for
## disk management during install (web-platform/shared.nix). Installed
## systems consume web-platform only as a source tree, so this module
## is the sole Cockpit on a deployed box.
{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.service-options.cockpit;

  ## VM support (cockpit-machines + libvirt/QEMU) is a separate opt-in
  ## on top of the app: it adds a hypervisor stack to the host.
  machinesEnabled = cfg.enable && cfg.machines-ui;

  ## libvirt's stock NAT network. NixOS (unlike Fedora/Debian) defines
  ## no 'default' network, so cockpit-machines would have nothing to
  ## attach a new VM's NIC to. Provisioned once by the oneshot below;
  ## the operator owns it afterwards (editable/deletable from Cockpit's
  ## Networks page, incl. changing the subnet should a deployment's LAN
  ## already use 192.168.122.0/24).
  libvirt-default-net-xml = pkgs.writeText "libvirt-default-network.xml" ''
    <network>
      <name>default</name>
      <forward mode='nat'/>
      <bridge name='virbr0' stp='on' delay='0'/>
      <ip address='192.168.122.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.122.2' end='192.168.122.254'/>
        </dhcp>
      </ip>
    </network>
  '';

  ## Pinned to Cockpit's universal default rather than auto-pooled: it
  ## matches the nixpkgs module's auto-appended https://localhost:9090
  ## origin and the documented `ssh -L 9090:127.0.0.1:9090` emergency
  ## path (docs/agent-notes/security-audit-phase-5.md H4). 9090 sits
  ## inside AUTO_POOL (9000–9099), but pass-1 pins claim first and the
  ## auto pass skips claimed ports.
  port = config.homefree.allocPort "cockpit";

  subdomain = "cockpit";
  http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
  https-domains = [ config.homefree.system.domain ];

  ## Cockpit rejects any WebSocket/XHR whose Origin header isn't listed,
  ## so this MUST stay in lockstep with the reverse-proxy entry below
  ## (same subdomain × domain cross product). The nixpkgs module
  ## auto-appends https://localhost:<port> for the ssh-tunnel path.
  allowed-origins = lib.unique (
    (map (d: "http://${subdomain}.${d}") http-domains)
    ++ (map (d: "https://${subdomain}.${d}") https-domains)
    ## Direct emergency access bypassing Caddy: cockpit-tls sniffs
    ## TLS-vs-plaintext on the same port, so https://<lan-ip>:9090
    ## still works even with AllowUnencrypted = true.
    ++ [ "https://${config.homefree.network.lan-address}:${toString port}" ]
  );

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable the Cockpit host system-management UI";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    podman-ui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bundle the cockpit-podman plugin (container list/logs/console).
        HomeFree's app containers are root podman system containers, so
        seeing them requires Cockpit's "administrative access" (sudo)
        toggle in the session.
      '';
    };

    machines-ui = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bundle the cockpit-machines plugin AND the virtualization stack
        it manages: libvirtd + QEMU/KVM, the libvirt-dbus bridge it
        speaks through, swtpm (emulated TPM for Windows-11-class
        guests), and virt-install (Cockpit's "Create VM" backend).
        Off by default — enabling this turns the box into a VM host.
      '';
    };
  };
in
{
  options.homefree.services.cockpit = userOptions;

  options.homefree.service-options.cockpit = userOptions // {
    # Metadata - always available, not user-configurable.
    label = lib.mkOption {
      type = lib.types.str;
      default = "cockpit";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Cockpit";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Cockpit Project";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    services.cockpit = lib.mkIf cfg.enable {
      enable = true;
      inherit port;

      ## HomeFree's nftables already accepts LAN and drops WAN; opening
      ## the NixOS firewall here would be redundant.
      openFirewall = false;

      ## No "Web console: https://<ip>:9090" lines in /etc/issue+motd —
      ## the canonical entry point is https://cockpit.<domain> via SSO.
      showBanner = false;

      plugins = lib.optional cfg.podman-ui pkgs.cockpit-podman
        ++ lib.optional cfg.machines-ui pkgs.cockpit-machines;

      ## The module owns WebService.Origins via this option — never set
      ## that key through `settings` or the two definitions conflict.
      inherit allowed-origins;

      settings = {
        ## Reverse-proxy posture (Caddy terminates TLS):
        ##  - AllowUnencrypted: accept plain HTTP from Caddy; direct LAN
        ##    https hits still work (cockpit-tls sniffs TLS vs plaintext
        ##    on the same port).
        ##  - Protocol/ForwardedFor headers: Caddy's reverse_proxy sets
        ##    X-Forwarded-Proto / X-Forwarded-For by default, and with
        ##    oauth2 enabled also `header_up Host {host}`.
        WebService = {
          AllowUnencrypted = true;
          ProtocolHeader = "X-Forwarded-Proto";
          ForwardedForHeader = "X-Forwarded-For";
        };

        ## Root-capable surface: log idle sessions out (minutes).
        Session.IdleTimeout = 15;
      };
    };

    ## cockpit.service (cockpit-tls) idle-exits CLEANLY (exit 0) shortly
    ## after the last connection closes; cockpit.socket then re-activates
    ## it on the next request. The fleet-wide restart policy
    ## (modules/service-restart-policy.nix) applies
    ## Restart = mkDefault "always" to every unit in
    ## systemd-service-names, which would resurrect the idle-exited ws
    ## forever and defeat socket activation. Normal-priority on-failure
    ## beats mkDefault and preserves upstream semantics.
    systemd.services.cockpit = lib.mkIf cfg.enable {
      serviceConfig.Restart = "on-failure";
    };

    ## --- VM support (machines-ui) -------------------------------------

    ## The VM stack for cockpit-machines. libvirtd runs as root by
    ## upstream design; cockpit-machines talks to it over libvirt-dbus,
    ## which runs as its own `libvirtdbus` system user, and per-login
    ## authorization keys on the `libvirtd` group (both the D-Bus policy
    ## and libvirtd's polkit rule).
    virtualisation.libvirtd = lib.mkIf machinesEnabled {
      enable = true;
      ## cockpit-machines speaks the libvirt-dbus API exclusively; the
      ## nixpkgs package even gates the plugin's manifest on
      ## /etc/systemd/system/libvirt-dbus.service existing. The unit is
      ## D-Bus-activated on demand (inactive until the first
      ## org.libvirt call — same shape as cockpit itself).
      dbus.enable = true;
      ## Emulated TPM so Windows-11-class guests can be created.
      qemu.swtpm.enable = true;
    };

    ## mkIf wraps the whole attrset (not the extraGroups leaves): a
    ## leaf-level mkIf would still CREATE the libvirtdbus user key with
    ## invalid defaults on boxes where machines-ui is off and fail the
    ## users-module assertions.
    users.users = lib.mkIf machinesEnabled {
      ## Let the admin user manage system VMs: the libvirt-dbus D-Bus
      ## policy and libvirtd's polkit rule both authorize the
      ## `libvirtd` group.
      ${config.homefree.system.adminUsername}.extraGroups = [ "libvirtd" ];

      ## The libvirt-dbus bridge connects to libvirtd as its own
      ## `libvirtdbus` system user, and libvirtd's polkit rule
      ## authorizes only the `libvirtd` group — which the NixOS module
      ## does NOT put the bridge user in (its nixos test only exercises
      ## the polkit-less Test driver, so the gap is invisible
      ## upstream). Without this, every cockpit-machines call fails
      ## with "authentication unavailable: no polkit agent available to
      ## authenticate action 'org.libvirt.unix.manage'". Fedora ships
      ## the same fix baked in (its package creates the user in the
      ## libvirt group). Who may reach the bridge at all is still gated
      ## by the D-Bus policy: root and `libvirtd` group members only.
      libvirtdbus.extraGroups = [ "libvirtd" ];
    };

    ## virt-install backs cockpit-machines' "Create VM" flow (the
    ## button reports it missing otherwise); virt-manager is the
    ## package that ships it.
    environment.systemPackages = lib.mkIf machinesEnabled [ pkgs.virt-manager ];

    ## Grant libvirt's NAT bridges the trusted-internal forwarding
    ## class. The router's forward chain is default-drop, and an accept
    ## in libvirt's own nftables table cannot override it (a packet
    ## must be accepted by EVERY table's hook), so VM traffic needs
    ## explicit accepts in the router table. "virbr*" also covers
    ## additional libvirt networks the operator may add (virbr1, ...).
    homefree.network.extra-trusted-interfaces =
      lib.mkIf machinesEnabled [ "virbr*" ];

    ## Bring up libvirt's 'default' NAT network: the NixOS libvirtd
    ## module pre-DEFINES it (libvirtd-config.service copies the
    ## package's qemu/networks/default.xml into /var/lib/libvirt) but
    ## leaves it inactive with autostart off, so cockpit-machines'
    ## Create-VM flow fails with "network 'default' is not active".
    ## Define is only a fallback should upstream stop shipping the
    ## XML; the real provisioning is autostart + start. Gated by a
    ## marker so it runs ONCE — if the operator later stops, deletes
    ## or replaces the network in Cockpit, a rebuild must not
    ## resurrect it (libvirt persists definition + autostart flag
    ## itself).
    systemd.services.libvirt-default-network = lib.mkIf machinesEnabled {
      description = "Provision libvirt's default NAT network";
      ## after dnsmasq too (ordering only, no dependency): net-start
      ## spawns libvirt's own dnsmasq for the bridge, and during the
      ## rebuild that first enables machines-ui the router dnsmasq is
      ## being restarted onto per-interface binds (bind-dynamic, see
      ## services/dnsmasq) — starting the network before that restart
      ## would race the old wildcard :67 socket and fail the bind.
      after = [ "libvirtd.service" "dnsmasq.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.virtualisation.libvirtd.package ];
      serviceConfig.Type = "oneshot";
      script = ''
        ## v2 marker: v1 bundled autostart+start inside the
        ## "network missing" branch, which never fires on NixOS
        ## (see above) — boxes marked by v1 have the network down.
        ## The new name re-runs provisioning once on those boxes.
        rm -f /var/lib/libvirt/.homefree-default-net-provisioned
        marker=/var/lib/libvirt/.homefree-default-net-provisioned-v2
        if [ -e "$marker" ]; then
          exit 0
        fi
        if ! virsh net-info default >/dev/null 2>&1; then
          virsh net-define ${libvirt-default-net-xml}
        fi
        virsh net-autostart default
        if ! virsh net-info default | grep -q '^Active:.*yes'; then
          virsh net-start default
        fi
        touch "$marker"
      '';
    };

    ## HomeFree's router ruleset opens with `flush ruleset`
    ## (profiles/router.nix), which wipes the NAT/filter rules libvirt
    ## maintains for its virtual networks in its own nftables table —
    ## on every nftables restart AND on the reload path a
    ## nixos-rebuild switch takes (reloadIfChanged). libvirtd
    ## re-creates the rules for active networks at daemon startup, so
    ## kick a try-restart after every ruleset apply. `-` prefix: never
    ## fail the firewall unit over the resync; --no-block: don't
    ## deadlock inside a switch transaction; try-restart: no-op at
    ## boot, where nftables starts before libvirtd and the rules
    ## arrive with libvirtd itself. Running VMs are unaffected — qemu
    ## processes are independent and libvirtd reconnects to them.
    systemd.services.nftables.serviceConfig = lib.mkIf machinesEnabled (
      let
        resync = "-${pkgs.systemd}/bin/systemctl --no-block try-restart libvirtd.service";
      in {
        ExecStartPost = [ resync ];
        ExecReload = lib.mkAfter [ resync ];
      }
    );

    ## Catalog entry emitted unconditionally with an `enable` flag (not
    ## wrapped in mkIf) so the admin UI lists the app while disabled and
    ## the restart policy skips its units without leaking a stub.
    homefree.service-config = [{
      inherit (cfg) label name project-name;
      enable = cfg.enable;
      port-request = 9090;

      ## Host app (NixOS-native, no OCI image): current version is the
      ## nixpkgs build; latest comes from upstream GitHub releases.
      ## Surfaces on the App Versions page via host-apps.json (no
      ## podman-* unit + non-"image" strategy).
      version-tracking = {
        strategy = "nixpkgs";
        repo = "cockpit-project/cockpit";
        current-version = pkgs.cockpit.version;
      };

      ## cockpit.socket owns the listener; the service unit is what the
      ## restart policy and admin status act on. "inactive" while no
      ## session is open is NORMAL for a socket-activated unit — the
      ## services-down alert source only fires on `failed`.
      systemd-service-names = [
        "cockpit"
      ];

      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Outer gate is admin-only. Cockpit has no OIDC — its inner
        ## login is PAM against host accounts. Mitigation:
        ## apps/zitadel/pam-bridge.nix syncs the OS admin user's
        ## password with Zitadel, so the inner login accepts the same
        ## credential the user just used for SSO. No documented GET
        ## logout path, so no upstream-logout-paths (accepted double
        ## login, same as Frigate / Z-Wave JS UI).
      };

      reverse-proxy = {
        enable = cfg.enable;
        subdomains = [ subdomain ];
        inherit http-domains https-domains;
        host = config.homefree.network.lan-address;
        inherit port;
        ssl = false;
        public = cfg.public;
        ## Admin-only gate: Cockpit is root-level host management
        ## (terminal, systemd, accounts). Restrict to homefree-admin.
        oauth2 = config.homefree.sso.per-service.cockpit.enable or true;
        require-admin-role = true;
      };

      ## No backup block: configuration is fully declarative
      ## (/etc/cockpit/cockpit.conf comes from this module) and
      ## sessions are ephemeral.

      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable the Cockpit host system-management UI";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make Cockpit accessible from WAN";
        }
        {
          path = "podman-ui";
          type = "bool";
          default = true;
          description = "Bundle the cockpit-podman container-management plugin";
        }
        {
          path = "machines-ui";
          type = "bool";
          default = false;
          description = "Bundle the cockpit-machines VM plugin plus the libvirt/QEMU/KVM stack (turns the box into a VM host)";
        }
      ];
    }];
  };
}
