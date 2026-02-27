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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-vm.sh"

# Check if cleanup script exists
if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
    err "Cleanup script not found: $CLEANUP_SCRIPT"
fi

# Copy cleanup script to VM and execute
log "Uploading cleanup script to VM..."
qm guest exec "$VMID" -- /bin/bash -s < "$CLEANUP_SCRIPT"

# Wait for cleanup to complete
log "Waiting for cleanup to complete (this may take a while)..."
sleep 5

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
