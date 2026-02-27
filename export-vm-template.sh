#!/bin/bash
set -euo pipefail

# PVE VM to Template Export Script
# Cleans VM and exports disk as QCOW2 template
#
# Usage: ./export-vm-template.sh <VMID> <OUTPUT_PATH>

VMID="${1:-900}"
OUTPUT_PATH="${2:-/root/debian-xfce-template.qcow2}"

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }
info() { printf "${BLUE}[i]${NC} %s\n" "$*"; }

# Check if VM exists
if ! qm status "$VMID" &>/dev/null; then
    err "VM $VMID does not exist"
fi

# Check if VM is running
if qm status "$VMID" | grep -q "status: running"; then
    log "VM $VMID is running, shutting down..."
    qm shutdown "$VMID"
    
    # Wait for VM to stop
    for i in {1..60}; do
        if ! qm status "$VMID" | grep -q "status: running"; then
            log "VM $VMID stopped"
            break
        fi
        sleep 1
    done
    
    # Force stop if still running
    if qm status "$VMID" | grep -q "status: running"; then
        warn "VM not stopped gracefully, forcing stop..."
        qm stop "$VMID"
    fi
fi

log "Starting VM cleanup..."

# Create cleanup script to run inside VM
CLEANUP_SCRIPT=$(mktemp)
cat > "$CLEANUP_SCRIPT" << 'VMCLEAN'
#!/bin/bash
set -e

echo "[VM] Cleaning apt cache..."
apt-get clean || true
apt-get autoremove -y || true
rm -rf /var/cache/apt/archives/*.deb || true

echo "[VM] Cleaning temporary files..."
rm -rf /tmp/* || true
rm -rf /var/tmp/* || true

echo "[VM] Cleaning logs..."
find /var/log -type f -exec truncate -s 0 {} \; || true
rm -f /var/log/*.gz || true
rm -f /var/log/*.[0-9] || true

echo "[VM] Cleaning user caches..."
for user_home in /home/* /root; do
    if [[ -d "$user_home/.cache" ]]; then
        rm -rf "$user_home/.cache"/* || true
    fi
done

echo "[VM] Cleaning shell history..."
history -c 2>/dev/null || true
for user_home in /home/* /root; do
    rm -f "$user_home/.bash_history" || true
    rm -f "$user_home/.history" || true
    rm -f "$user_home/.sh_history" || true
done

echo "[VM] Cleaning WPS cache..."
for user_home in /home/*; do
    rm -rf "$user_home/.wps-office" || true
done

echo "[VM] Cleaning OpenClaw..."
for user_home in /home/* /root; do
    rm -rf "$user_home/.openclaw" || true
done

echo "[VM] Cleaning journal logs..."
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -rf /var/log/journal/* || true

echo "[VM] Zeroing free space..."
dd if=/dev/zero of=/zerofile bs=1M status=none || true
sync
rm -f /zerofile

echo "[VM] Cleanup complete"
VMCLEAN

# Copy script to VM and execute
log "Uploading cleanup script to VM..."
cat "$CLEANUP_SCRIPT" | qm guest exec "$VMID" -- bash -s

# Wait for cleanup to complete
log "Waiting for cleanup to complete (this may take a while)..."
sleep 5

# Cleanup temp file
rm -f "$CLEANUP_SCRIPT"

# Shutdown VM
log "Shutting down VM..."
qm shutdown "$VMID"

# Wait for VM to stop
for i in {1..60}; do
    if ! qm status "$VMID" | grep -q "status: running"; then
        log "VM stopped"
        break
    fi
    sleep 1
done

# Verify VM is stopped
if qm status "$VMID" | grep -q "status: running"; then
    err "Failed to stop VM"
fi

# Get disk information
info "Getting disk information..."
DISK_INFO=$(qm config "$VMID" | grep "^scsi0:" | awk '{print $2}')
STORAGE=$(echo "$DISK_INFO" | cut -d: -f1)
DISK_NAME=$(echo "$DISK_INFO" | cut -d: -f2)

log "Source disk: $STORAGE:$DISK_NAME"
log "Output path: $OUTPUT_PATH"

# Export disk
log "Exporting disk to QCOW2 format..."
qm disk export "$VMID" "$DISK_NAME" "$OUTPUT_PATH" --format qcow2

# Verify export
if [[ -f "$OUTPUT_PATH" ]]; then
    SIZE=$(ls -lh "$OUTPUT_PATH" | awk '{print $5}')
    log "✓ Template exported successfully!"
    info "File: $OUTPUT_PATH"
    info "Size: $SIZE"
else
    err "Failed to export template"
fi

# Cleanup: Remove temporary snapshot if any
qm snapshot list "$VMID" 2>/dev/null | grep -v "^ID" | awk '{print $1}' | while read -r snapshot; do
    warn "Found snapshot: $snapshot"
    read -p "Delete snapshot? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        qm snapshot delete "$VMID" "$snapshot"
    fi
done

log "Export complete!"
echo ""
echo "Template details:"
echo "  VM ID: $VMID"
echo "  Output: $OUTPUT_PATH"
echo "  Size: $(ls -lh "$OUTPUT_PATH" | awk '{print $5}')"
echo ""
echo "To create a new VM from this template:"
echo "  qm create <NEW_VMid> --name <name>"
echo "  qm importdisk <NEW_VMid> $OUTPUT_PATH <storage>"
echo "  qm set <NEW_VMid> --scsi0 <storage>:vm-<NEW_VMid>-disk-0"
