# libvirt bridges (and any future host bridge) vs the router firewall

Context: added when wiring cockpit-machines / libvirt VM support into
`apps/cockpit/default.nix` (the `machines-ui` option). Applies to ANY
service that creates its own host bridge with its own firewall rules
(libvirt, future wireguard/VPN bridges, etc.).

## 1. An `accept` in another table cannot override our `drop`

nftables runs a packet through the hooks of EVERY table. A verdict of
`accept` in one table only ends processing *in that table* — the packet
must still pass every other table's hook, and a `drop` anywhere is
final. libvirt (with its nftables backend, the default when
`networking.nftables.enable` is set) maintains its own `libvirt_network`
table with accepts for its bridges — those do NOTHING against the
router's default-drop `forward` chain in `table inet filter`.

Fix / extension point: `homefree.network.extra-trusted-interfaces`
(declared in `module.nix`, consumed by `profiles/router.nix`). A module
that creates a trusted host bridge pushes its interface name (nftables
trailing-asterisk prefix patterns like `"virbr*"` are supported) and the
router emits the same trust class as the podman bridges: input accept +
forward to/from LAN and WAN with established return paths. NAT for the
bridge's subnet stays with whoever owns the bridge (libvirt masquerades
its NAT net from its own table).

## 2. `flush ruleset` wipes the OTHER tables too

`profiles/router.nix`'s ruleset opens with `flush ruleset`, which
deletes ALL tables — including libvirt's. The NixOS nftables unit has
`reloadIfChanged = true`, so a plain `nixos-rebuild switch` takes the
*reload* path (ExecReload) and silently wipes libvirt's NAT/filter
rules: VMs keep running but lose connectivity ("worked until I
rebuilt").

Fix (in `apps/cockpit/default.nix`, gated on machines-ui): append a
`-…systemctl --no-block try-restart libvirtd.service` to BOTH
`ExecStartPost` and `ExecReload` of `nftables.service` — libvirtd
re-creates the rules for active networks at daemon startup, qemu
processes are independent so running VMs are unaffected. `PartOf=` is
NOT sufficient: it propagates restarts but not reloads, and reload is
the path a rebuild takes.

## 3. Misc facts that cost time

- cockpit-machines speaks **libvirt-dbus only**; nixpkgs gates the
  plugin's manifest on `/etc/systemd/system/libvirt-dbus.service`
  existing. `virtualisation.libvirtd.dbus.enable = true` provides it
  (D-Bus-activated, sits inactive until the first org.libvirt call).
  Authorization for both the D-Bus policy and libvirtd's polkit rule
  keys on the `libvirtd` group — put the admin user in it.
- **The bridge user needs the group too.** libvirt-dbus connects to
  libvirtd as its own `libvirtdbus` system user, which the NixOS module
  leaves OUT of the `libvirtd` group, so every qemu:///system call dies
  with "authentication unavailable: no polkit agent available to
  authenticate action 'org.libvirt.unix.manage'" — even though the page
  loads and the admin's own `virsh -c qemu:///system` works. The
  upstream nixos test never catches this because it uses the polkit-less
  Test driver. Fix: `users.users.libvirtdbus.extraGroups =
  [ "libvirtd" ]` (Fedora bakes the same membership into its package).
- The NixOS libvirtd module pre-DEFINES the 'default' NAT network
  (libvirtd-config.service copies the package's
  qemu/networks/default.xml into /var/lib/libvirt) but leaves it
  **inactive with autostart off** — so "network 'default' is not
  active" on Create VM. Any provisioner must run `net-autostart` +
  `net-start` INDEPENDENTLY of whether the definition exists; gating
  them behind "network missing" never fires on NixOS. `apps/cockpit`
  does this via a marker-gated oneshot (one-shot so an operator's
  later stop/deletion in Cockpit's UI is not resurrected by the next
  rebuild).
- Diagnosis trap: unprivileged `virsh net-list`/`net-info` (no -c)
  talks to **qemu:///session**, which is empty, and reports "Network
  not found" even though qemu:///system has the network. Always probe
  with sudo or `-c qemu:///system`.
- **The router's dnsmasq blocked libvirt's dnsmasq.** dnsmasq's
  default is a wildcard 0.0.0.0:67 socket (interface= only filters
  requests, not the bind), so libvirt's per-network dnsmasq failed
  `net-start` with "failed to bind DHCP server socket: Address already
  in use". Fix in `services/dnsmasq/default.nix`: `bind-dynamic =
  true` (per-address sockets, tracks late-appearing interfaces — which
  the guest-network VLANs want anyway). The libvirt-default-network
  oneshot is additionally ordered `after dnsmasq.service` so the
  first-enable rebuild can't start the network against the old
  wildcard socket.
- Cockpit's "Create VM" needs `virt-install`, shipped by
  `pkgs.virt-manager`.
- Verification trap: the flake's `homefree` nixosConfiguration is an
  eval/test config where `profiles/router.nix` is gated OFF
  (`homefree.network.router.enable` defaults false; the test only
  forces `networking.nftables.enable` for an assertion) — its rendered
  `networking.nftables.ruleset` is EMPTY. To check rendered firewall
  rules, eval with `extendModules` setting
  `homefree.network.router.enable = true`, then run `nft --check -f`
  on the result.
