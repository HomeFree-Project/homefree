# Fast Development Workflow with SSH

## Quick Start

After the ISO is built with SSH enabled, you can make changes directly in the VM without rebuilding.

### SSH into the VM

```bash
# From your host terminal:
ssh -p 2223 nixos@localhost
# Password: nixos

# Or as root:
ssh -p 2223 root@localhost
# Password: root
```

## Development Loop

### 1. Edit Backend Files

```bash
# SSH into VM
ssh -p 2223 nixos@localhost

# Edit backend files (as root or with sudo)
sudo nano /etc/homefree-installer/backend/simple_main.py
sudo nano /etc/homefree-installer/backend/models.py
sudo nano /etc/homefree-installer/backend/resolvers/system.py

# Restart backend to apply changes
sudo systemctl restart homefree-installer-backend

# Watch logs in real-time
sudo journalctl -u homefree-installer-backend -f

# Check if service is running
sudo systemctl status homefree-installer-backend
```

### 2. Edit Frontend Files

```bash
# Edit frontend HTML/JS (no service restart needed)
sudo nano /etc/homefree-installer/frontend/index.html
sudo nano /etc/homefree-installer/frontend/src/app.js
sudo nano /etc/homefree-installer/frontend/src/components/network-step.js

# Just reload browser to see changes!
```

### 3. Test API from VM

```bash
# Inside VM, test backend:
curl http://localhost:8000/health
curl http://localhost:8000/api/status
curl http://localhost:8000/api/network/interfaces
```

### 4. Test from Host

```bash
# From your host machine:
curl http://localhost:8000/health
curl http://localhost:8000/api/network/interfaces

# Or open in browser:
firefox http://localhost:8000
```

## Common Tasks

### Restart Backend Service
```bash
sudo systemctl restart homefree-installer-backend
```

### View Backend Logs
```bash
# Follow logs in real-time
sudo journalctl -u homefree-installer-backend -f

# View last 50 lines
sudo journalctl -u homefree-installer-backend -n 50
```

### Check What's Running
```bash
# See if backend is listening on port 8000
sudo ss -tlnp | grep 8000

# Check service status
sudo systemctl status homefree-installer-backend
```

### Copy Files from Host to VM

```bash
# From host, use scp:
scp -P 2223 /path/to/file.py nixos@localhost:/tmp/
# Then in VM: sudo cp /tmp/file.py /etc/homefree-installer/backend/
```

### Copy Changes Back to Host

```bash
# After testing changes in VM, copy back to host:
scp -P 2223 nixos@localhost:/etc/homefree-installer/backend/simple_main.py ~/Code/homefree/installer-web/backend/

# Or just re-implement the working changes in your host repo
```

## File Locations in VM

```
/etc/homefree-installer/
├── backend/
│   ├── simple_main.py          # Main API server
│   ├── models.py               # Data models
│   ├── resolvers/
│   │   ├── system.py           # System info resolver
│   │   ├── network.py          # Network resolver
│   │   ├── config.py           # Config resolver
│   │   └── install.py          # Install resolver
│   └── services/
│       ├── network.py          # Network detection
│       ├── config.py           # Config storage
│       └── install.py          # Installation logic
└── frontend/
    ├── index.html              # Main HTML
    └── src/
        ├── app.js              # App entry point
        ├── api/
        │   └── client.js       # REST API client
        └── components/
            ├── installer-app.js
            ├── network-step.js
            └── ...
```

## Benefits

**Before (slow)**:
- Edit file on host
- Git add
- Rebuild ISO (5-10 minutes)
- Restart VM
- Test
- **Total: 10-15 minutes per change**

**After (fast)**:
- SSH into VM
- Edit file
- Restart service (2 seconds)
- Test
- **Total: 30 seconds per change**

## When to Rebuild ISO

Only rebuild when you need to:
- Test the full installation from scratch
- Test changes to system services/configuration in `default.nix`
- Create a final release ISO

For iterative development of backend/frontend code, use SSH!

## Tips

- **Keep VM running** while developing
- **Use tmux or screen** in VM to have multiple terminals
- **Watch logs** in one terminal while editing in another
- **Test frequently** - changes apply immediately
- **Save working changes** back to host repo periodically
