# HomeFree Web-Based Installer

A modern, web-based installer for HomeFree NixOS that **completely replaces** Calamares with a browser-based interface.

## 🚀 What Happens When You Boot

1. **GNOME desktop loads** (no Calamares window)
2. **Backend starts automatically** (systemd service)
3. **Firefox launches in kiosk mode** after 5 seconds
4. **Web installer loads** at `http://localhost:8000`

**Calamares is disabled** - the web interface is your installer!

## Overview

The web installer provides a streamlined installation experience with:

- **Modern UI** built with LitHTML and modern web technologies
- **GraphQL API** backend for installation management
- **Cockpit Storage integration** for professional disk partitioning
- **Real-time progress updates** during installation
- **Network detection** for automatic WAN/LAN interface configuration
- **Auto-launch** - Opens automatically on boot, no manual intervention

## Architecture

### Frontend (`frontend/`)
- **Framework**: LitHTML (lightweight, standards-based)
- **API Client**: urql (GraphQL client)
- **Build Tool**: Vite
- **Components**:
  - Welcome screen
  - Network interface selection (WAN/LAN)
  - Location and timezone
  - Keyboard layout
  - Disk partitioning (with Cockpit Storage integration)
  - User account setup
  - Installation summary
  - Installation progress
  - Completion screen

### Backend (`backend/`)
- **Framework**: FastAPI + Strawberry GraphQL
- **Language**: Python 3
- **Services**:
  - System information detection
  - Network interface detection (ported from Calamares)
  - Configuration management
  - Installation execution (nixos-install, nixos-generate-config)
  - Config file generation (flake.nix, homefree-configuration.nix)

### Integration
- **Cockpit Storage**: Professional disk partitioning UI
- **Automatic browser launch**: Firefox in kiosk mode on boot
- **Systemd services**: Auto-start backend and frontend

## Installation Steps

The installer guides users through:

1. **Welcome** - Introduction and language selection
2. **Network** - WAN and LAN interface selection (HomeFree-specific)
   - **Development Mode** (QEMU/KVM only) - Optional development configuration
3. **Location** - Timezone and locale selection
4. **Keyboard** - Keyboard layout configuration
5. **Partitioning** - Automatic or manual (Cockpit Storage) disk setup
6. **Users** - Admin username, password, and hostname
7. **Summary** - Review all settings before installation
8. **Install** - Real-time installation progress
9. **Finished** - Completion with next steps

## Development Mode (QEMU/KVM)

When the installer detects it's running in a QEMU/KVM virtual machine, it offers a **Development Mode** option. This mode configures the system for development with a shared folder setup for live code editing.

### What Development Mode Does

When enabled, the installer:

1. **Configures QEMU User Networking**:
   - Sets LAN address to `10.0.2.15` (QEMU default)
   - Configures subnet as `10.0.2.0/24`
   - Sets DHCP range to `10.0.2.100-10.0.2.200`

2. **Sets Up Shared Folder Mount Point**:
   - Creates `/home/<username>/homefree` directory
   - Sets proper ownership for the user
   - Adds a README with mounting instructions

3. **Configures Flake for Local Development**:
   - Adds `homefree-local` input pointing to local path
   - Modifies flake to use local code instead of git repository
   - Creates `development-overrides.nix` for dev-specific settings

4. **Enables Live Code Editing**:
   - Changes take effect immediately when mounted
   - Run `sudo nixos-rebuild switch` to apply changes

### Setting Up QEMU Shared Folder

After installation, configure your QEMU VM to share the homefree codebase:

#### 1. Add Shared Folder to QEMU Command

```bash
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -enable-kvm \
  -drive file=/path/to/disk.qcow2,format=qcow2 \
  -virtfs local,path=/path/to/homefree/on/host,mount_tag=homefree,security_model=passthrough,id=homefree \
  -boot c
```

Replace `/path/to/homefree/on/host` with your host machine's homefree repository path.

#### 2. Mount the Shared Folder (Inside VM)

```bash
# Manual mount
sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 homefree /home/<username>/homefree

# Or add to /etc/fstab for automatic mounting
echo "homefree /home/<username>/homefree 9p trans=virtio,version=9p2000.L,msize=104857600 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

#### 3. Verify Setup

```bash
ls -la /home/<username>/homefree
# Should show your host's homefree files

# Test rebuilding with local changes
cd /etc/nixos
sudo nixos-rebuild switch
```

### Development Workflow

1. **Edit code on your host machine** using your preferred IDE/editor
2. **Changes appear instantly** in the VM via shared folder
3. **Rebuild the system** in the VM: `sudo nixos-rebuild switch`
4. **Test your changes** immediately

### Disabling Development Mode

To switch back to using the git repository:

1. Edit `/etc/nixos/flake.nix`
2. Change the flake to use `homefree-base` instead of `homefree-local`
3. Remove the `homefree-local` input
4. Remove `./development-overrides.nix` from imports in `configuration.nix`
5. Run `sudo nixos-rebuild switch`

### Detection Logic

The installer detects QEMU/KVM using:
- `systemd-detect-virt` command
- Fallback to DMI product name check (`/sys/class/dmi/id/product_name`)

Development mode is only offered when virtualization is detected and defaults to **enabled**.

## Development

### Prerequisites
- Nix with flakes enabled
- Node.js (for frontend development)
- Python 3 (for backend development)

### Local Development

#### Frontend
```bash
cd frontend
npm install
npm run dev  # Starts Vite dev server on :3000
```

#### Backend
```bash
cd backend
pip install -r requirements.txt
python main.py  # Starts GraphQL server on :8000
```

### Building the Installer ISO

```bash
# From project root - Web installer (default)
./scripts/build-image.sh
# OR
nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage

# To build legacy Calamares installer (backup)
nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage
```

The ISO will be in `./build/` (using script) or `result/iso/` (using nix build directly).

### Testing

Use the provided test script:

```bash
# Build the installer
./scripts/test-web-installer.sh build

# Test in QEMU
./scripts/test-web-installer.sh test

# Clean build artifacts
./scripts/test-web-installer.sh clean
```

Or manually with QEMU:
```bash
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -enable-kvm \
  -cdrom result/iso/homefree-web-installer.iso \
  -boot d
```

## Key Differences from Calamares

| Feature | Calamares | Web Installer |
|---------|-----------|---------------|
| UI Framework | Qt/QML | LitHTML (Web) |
| Language | C++/Python | Python/JavaScript |
| Partitioning | Built-in | Cockpit Storage |
| API | Internal | GraphQL |
| Extensibility | Limited | Highly modular |
| Browser-based | No | Yes |
| Real-time updates | Limited | WebSocket support |

## Configuration Templates

The installer generates three key files:

### flake.nix
Points to HomeFree repository and configures NixOS system.

### homefree-configuration.nix
Contains HomeFree-specific settings:
- System identity (hostname, timezone, locale)
- Network interfaces (WAN/LAN)
- Admin user configuration
- Service enablement

### configuration.nix
System-specific overrides (bootloader, stateVersion, hardware imports).

## Cockpit Storage Integration

The installer embeds Cockpit Storage for advanced disk management:

- **Automatic mode**: Simple "erase disk" option
- **Manual mode**: Full Cockpit Storage UI for:
  - Partition table creation (GPT/MBR)
  - Filesystem selection
  - LVM configuration
  - RAID setup
  - LUKS encryption

Access during installation: `http://localhost:9090/storage`

## GraphQL API

### Queries
- `systemInfo` - Hardware detection
- `networkInterfaces` - Network interface list
- `timezones` - Available timezones
- `keyboardLayouts` - Keyboard layouts
- `installSummary` - Current configuration
- `installProgress` - Installation status

### Mutations
- `setNetworkConfig` - Configure WAN/LAN
- `setLocation` - Set timezone/locale
- `setKeyboard` - Set keyboard layout
- `setUser` - Configure user account
- `setHostname` - Set system hostname
- `setPartitioning` - Configure disk layout
- `startInstallation` - Begin installation

## Network Detection

The network detection service automatically identifies:
- Physical ethernet interfaces
- MAC addresses
- Link speed and carrier status
- Distinguishes real hardware from virtual interfaces

This ensures proper WAN/LAN interface selection for router functionality.

## Installation Process

The backend performs:

1. **Partitioning** - Format and mount disks
2. **Hardware detection** - `nixos-generate-config`
3. **Config generation** - Create flake.nix and configs
4. **Git initialization** - Initialize /etc/nixos repo
5. **System installation** - `nixos-install` with flake
6. **Post-install** - Set passwords, finalize

Progress is streamed to the frontend via GraphQL polling.

## Security Considerations

- Backend runs as root (required for disk operations)
- Frontend served over HTTP (live ISO, no network exposure)
- Passwords handled securely (never logged)
- Git repo initialized with dummy credentials
- Cockpit uses local authentication only

## Future Enhancements

- [ ] Real-time GraphQL subscriptions (WebSocket)
- [ ] Automatic disk partitioning logic
- [ ] Multiple disk support
- [ ] Custom partition layouts
- [ ] Encrypted swap support
- [ ] Advanced network configuration
- [ ] Service selection wizard
- [ ] Backup configuration import

## Troubleshooting

### Browser doesn't auto-launch
Check systemd service:
```bash
systemctl status homefree-installer-browser
journalctl -u homefree-installer-browser
```

### Backend not responding
Check backend service:
```bash
systemctl status homefree-installer-backend
journalctl -u homefree-installer-backend
```

### Cockpit Storage not accessible
Check Cockpit service:
```bash
systemctl status cockpit
```

### Installation fails
Check logs:
```bash
journalctl -u homefree-installer-backend -f
```

## Contributing

When adding new features:

1. Update GraphQL schema in `backend/schema.py`
2. Implement resolvers in `backend/resolvers/`
3. Add frontend components in `frontend/src/components/`
4. Update this README

## License

Same as HomeFree project (see root LICENSE file).
