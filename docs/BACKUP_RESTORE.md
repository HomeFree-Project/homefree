# HomeFree Backup and Restore Guide

## Overview

HomeFree implements a 3-2-1 backup strategy:
- **3 copies** of data: original + 2 backups
- **2 different** storage locations: local storage + Backblaze B2
- **1 offsite** backup: Backblaze B2

## Backup Architecture

### Components

1. **Restic**: Encrypted, deduplicated incremental backups
2. **Local Storage**: Primary backup location (`/var/lib/backups` by default)
3. **Backblaze B2**: Offsite backup via rclone mount + rsync
4. **Database Dumps**: PostgreSQL and MySQL dumps before backup

### Service-Level Backups

Each service gets its own Restic repository with independent snapshots:
- Service data directories (e.g., `/var/lib/containers/nextcloud`)
- Database dumps (if the service uses databases)
- Configuration files

### Retention Policy

- **Daily**: 7 snapshots
- **Weekly**: 5 snapshots
- **Yearly**: 10 snapshots

## Configuration

### Enable Backups

```nix
{
  homefree = {
    backups = {
      enable = true;
      to-path = "/var/lib/backups";  # Local backup storage

      # Optional: Enable Backblaze B2 sync
      backblaze = {
        enable = true;
        bucket = "homefree-backups";
      };

      # Optional: Extra paths to backup
      extra-from-paths = [
        "/home/admin/important-data"
      ];

      secrets = {
        restic-password = "/path/to/restic-password";
        restic-environment = "/path/to/restic-environment";
        backblaze-id = "/path/to/backblaze-id";
        backblaze-key = "/path/to/backblaze-key";
      };
    };
  };
}
```

### Service Backup Configuration

Services automatically backup paths configured in `homefree.service-config`:

```nix
{
  label = "nextcloud";
  backup = {
    paths = [ "/var/lib/containers/nextcloud" ];
    postgres-databases = [ "nextcloud" ];
  };
}
```

## Backup Commands

### View Backup Status

```bash
# List all services with backups
sudo backup-cli

# Check systemd backup timers
systemctl list-timers | grep restic

# Check Backblaze sync status
systemctl status rclone-backblaze
systemctl status restic-backblaze-rsync
```

### Manual Backup

```bash
# Run backup for a specific service
sudo systemctl start restic-backups-local-nextcloud

# Run all backups
sudo systemctl start restic-backups-local-*

# Sync to Backblaze
sudo systemctl start restic-backblaze-rsync
```

## Restore Commands

HomeFree includes a comprehensive `restore-cli` tool for disaster recovery.

### List Available Backups

```bash
# List all services with backups
sudo restore-cli list-services

# List snapshots for a specific service
sudo restore-cli list-snapshots nextcloud
```

### Download from Backblaze

```bash
# Download specific service backup
sudo restore-cli download nextcloud

# Download all backups
sudo restore-cli download-all
```

### Restore Services

```bash
# Restore latest snapshot of a service
sudo restore-cli restore nextcloud

# Restore specific snapshot by ID
sudo restore-cli restore nextcloud a1b2c3d4

# Restore from local backups (skip download)
sudo restore-cli restore nextcloud --local

# Restore all services
sudo restore-cli restore-all
```

### Restore Options

- `--local`: Use local backups instead of Backblaze
- `--backup-path PATH`: Override local backup path
- `--mount-path PATH`: Override Backblaze mount path
- `--source SOURCE`: Specify source (`local`, `backblaze`, or `auto`)

## Disaster Recovery Workflow

### Scenario: Complete System Rebuild

1. **Install HomeFree** on new hardware using installer
2. **Configure system** with same configuration as before
3. **Setup backup credentials**:
   ```bash
   # Create secret directories
   sudo mkdir -p /run/secrets/backup

   # Add restic password
   echo "your-restic-password" | sudo tee /run/secrets/backup/restic-password

   # Add Backblaze credentials (if using)
   echo "your-b2-id" | sudo tee /run/secrets/backup/backblaze-id
   echo "your-b2-key" | sudo tee /run/secrets/backup/backblaze-key
   ```

4. **Mount Backblaze** (if using offsite backup):
   ```bash
   sudo systemctl start rclone-backblaze
   ```

5. **Download all backups**:
   ```bash
   sudo restore-cli download-all
   ```

6. **Restore all services**:
   ```bash
   sudo restore-cli restore-all
   ```

### Scenario: Single Service Recovery

1. **List available snapshots**:
   ```bash
   sudo restore-cli list-snapshots nextcloud
   ```

2. **Restore specific service**:
   ```bash
   # Latest snapshot
   sudo restore-cli restore nextcloud

   # Or specific snapshot
   sudo restore-cli restore nextcloud a1b2c3d4
   ```

The restore process will:
- Stop the service
- Restore files to their original locations
- Restore database dumps and re-import them
- Restart the service

### Scenario: Point-in-Time Recovery

1. **Find snapshot from specific date**:
   ```bash
   sudo restore-cli list-snapshots nextcloud
   # Note the snapshot ID from desired date
   ```

2. **Restore that snapshot**:
   ```bash
   sudo restore-cli restore nextcloud <snapshot-id>
   ```

## Advanced Usage

### Manual Restic Commands

```bash
# Export restic password
export RESTIC_PASSWORD=$(cat /run/secrets/backup/restic-password)

# Browse a backup
export RESTIC_REPOSITORY=/var/lib/backups/nextcloud
sudo restic ls latest

# Mount a backup for browsing
sudo mkdir -p /mnt/restic
sudo restic mount /mnt/restic
# Browse files, then unmount
sudo fusermount -u /mnt/restic

# Restore specific files
sudo restic restore latest --target /tmp/restore --include /path/to/file
```

### Verify Backup Integrity

```bash
export RESTIC_PASSWORD=$(cat /run/secrets/backup/restic-password)
export RESTIC_REPOSITORY=/var/lib/backups/nextcloud

# Check repository consistency
sudo restic check

# Check with full data verification
sudo restic check --read-data
```

### Pruning Old Snapshots

Pruning happens automatically, but you can trigger it manually:

```bash
export RESTIC_PASSWORD=$(cat /run/secrets/backup/restic-password)
export RESTIC_REPOSITORY=/var/lib/backups/nextcloud

sudo restic forget --prune \
  --keep-daily 7 \
  --keep-weekly 5 \
  --keep-yearly 10
```

## Troubleshooting

### Backblaze Not Mounting

```bash
# Check service status
systemctl status rclone-backblaze

# Check logs
journalctl -u rclone-backblaze -f

# Verify credentials
cat /run/secrets/backup/backblaze-id
cat /run/secrets/backup/backblaze-key

# Restart service
sudo systemctl restart rclone-backblaze
```

### Backup Failing

```bash
# Check service logs
journalctl -u restic-backups-local-nextcloud -f

# Verify restic password
cat /run/secrets/backup/restic-password

# Check disk space
df -h /var/lib/backups

# Manual test
export RESTIC_PASSWORD=$(cat /run/secrets/backup/restic-password)
export RESTIC_REPOSITORY=/var/lib/backups/nextcloud
sudo restic snapshots
```

### Restore Not Finding Service

```bash
# Verify backup exists
sudo restore-cli list-services

# Check backup source
ls -la /var/lib/backups/
# or
ls -la /mnt/backup-backblaze/

# Specify source explicitly
sudo restore-cli restore nextcloud --source local
# or
sudo restore-cli restore nextcloud --source backblaze
```

### Database Restore Issues

PostgreSQL:
```bash
# Check if database exists
sudo -u postgres psql -l

# Create database if needed
sudo -u postgres createdb nextcloud

# Restore manually
gunzip -c /tmp/homefree-restore/nextcloud/var/backup/postgresql-homefree/nextcloud/nextcloud.sql.gz | \
  sudo -u postgres psql nextcloud
```

MySQL:
```bash
# Check if database exists
mysql -e "SHOW DATABASES;"

# Create database if needed
mysql -e "CREATE DATABASE nextcloud;"

# Restore manually
gunzip -c /tmp/homefree-restore/nextcloud/var/backup/mysql-homefree/nextcloud/nextcloud.gz | \
  mysql nextcloud
```

## Security Considerations

### Encryption

- All Restic backups are encrypted with the password in `restic-password`
- Backblaze transfer uses HTTPS
- Keep the restic password safe - **without it, backups cannot be restored**

### Access Control

- Backups run as root
- Secret files should be owned by root with mode 600:
  ```bash
  sudo chown root:root /run/secrets/backup/*
  sudo chmod 600 /run/secrets/backup/*
  ```

### Backup Testing

Regularly test your backups:

```bash
# Test restore to temporary location
sudo restore-cli restore nextcloud
# Verify service works
# If good, you have confirmed backup integrity
```

## Best Practices

1. **Test restores regularly** - Monthly test restores to verify backup integrity
2. **Monitor backup jobs** - Check systemd timers and logs weekly
3. **Secure credentials** - Store restic password and B2 keys safely offline
4. **Verify offsite sync** - Confirm Backblaze sync runs successfully
5. **Document your setup** - Keep notes on service configurations
6. **Plan for disasters** - Have a documented recovery procedure
7. **Monitor disk usage** - Ensure backup storage doesn't fill up

## Migration Workflow

When migrating HomeFree to new hardware:

1. On old system:
   - Ensure all backups are up to date
   - Verify Backblaze sync completed
   - Save all configuration files
   - Export secret files securely

2. On new system:
   - Install HomeFree from installer
   - Apply same NixOS configuration
   - Restore secret files
   - Mount Backblaze
   - Download and restore all services
   - Verify all services work correctly

3. After verification:
   - Update DNS records if needed
   - Decommission old system
   - Continue regular backup schedule
