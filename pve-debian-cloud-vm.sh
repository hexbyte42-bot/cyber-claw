#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# PVE Debian Cloud Image VM Creator
# 用于创建适合 cyber-claw (XFCE + XRDP + OpenClaw) 的 Debian 虚拟机
# =============================================================================

# 配置参数 (可自定义)
VMID="${VMID:-900}"                    # VM ID
VM_NAME="${VM_NAME:-debian-xfce}"       # VM 名称
STORAGE="${STORAGE:-local-lvm}"         # 存储位置
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"  # Debian 版本 (12=bookworm, 13=trixie)
LOCAL_IMAGE_PATH="${LOCAL_IMAGE_PATH:-}" # 本地 cloud image 路径 (留空则自动下载)
DISK_SIZE="${DISK_SIZE:-50G}"           # 磁盘大小
MEMORY="${MEMORY:-4096}"                # 内存 (MB)
CPU_CORES="${CPU_CORES:-4}"             # CPU 核心数

# 网络配置
BRIDGE="${BRIDGE:-vmbr0}"               # 网桥
IP_ADDR="${IP_ADDR:-dhcp}"              # 静态 IP 或 dhcp
GATEWAY="${GATEWAY:-}"                  # 网关 (dhcp 时留空)
DNS="${DNS:-8.8.8.8}"                   # DNS

# Cloud-init 用户配置
CI_USER="${CI_USER:-claw}"              # 用户名
CI_PASSWORD="${CI_PASSWORD:-}"          # 密码 (留空则使用 SSH key)
CI_SSH_KEY="${CI_SSH_KEY:-}"            # SSH 公钥 (可选，从 ~/.ssh/id_ed25519.pub 读取)
CI_TIMEZONE="${CI_TIMEZONE:-Asia/Shanghai}"
CI_LOCALE="${CI_LOCALE:-zh_CN.UTF-8}"

# 运行时状态变量
SSH_KEY_CONFIGURED=0                    # SSH key 是否已配置

# 颜色输出
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { printf "${GREEN}[+]${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; }
err() { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
info() { printf "${BLUE}[i]${NC} %s\n" "$*" >&2; }

# =============================================================================
# 前置检查
# =============================================================================
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v pvesm &>/dev/null; then
        err "This script must run on a Proxmox VE node (pvesm not found)"
    fi
    
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must run as root"
    fi
    
    if qm status "$VMID" &>/dev/null; then
        err "VM ID $VMID already exists. Choose a different VMID or remove it first."
    fi
    
    # 检查存储空间
    local pvesm_output
    pvesm_output=$(pvesm status 2>/dev/null | grep "^${STORAGE}[[:space:]]" | head -1)
    
    if [[ -z "$pvesm_output" ]]; then
        err "Storage '$STORAGE' not found. Run 'pvesm status' to list available storages."
    fi
    
    local available_kb
    available_kb=$(echo "$pvesm_output" | awk '{print $6}')
    local available_space=0
    
    if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        available_space=$((available_kb * 1024))
    fi
    
    local required_space=$((50 * 1024 * 1024 * 1024))
    
    if [[ "$available_space" -lt "$required_space" ]]; then
        local available_gb
        available_gb=$(awk "BEGIN {printf \"%.1f\", $available_space / 1024 / 1024 / 1024}")
        err "Insufficient storage on $STORAGE. Need at least 50GB free. (Available: ${available_gb}GB)"
    fi
    
    log "Prerequisites check passed."
}

# =============================================================================
# 获取 Cloud Image (本地或下载)
# =============================================================================
get_cloud_image() {
    local image_name="debian-${DEBIAN_VERSION}-genericcloud-amd64.qcow2"
    local image_path="/tmp/${image_name}"
    
    if [[ -n "$LOCAL_IMAGE_PATH" ]]; then
        if [[ -f "$LOCAL_IMAGE_PATH" ]]; then
            log "Using local cloud image: $LOCAL_IMAGE_PATH"
            cp "$LOCAL_IMAGE_PATH" "$image_path"
            echo "$image_path"
            return 0
        else
            err "Local image not found: $LOCAL_IMAGE_PATH"
        fi
    fi
    
    if [[ -f "$image_path" ]]; then
        log "Found existing image at $image_path, skipping download"
        echo "$image_path"
        return 0
    fi
    
    local image_url
    case "$DEBIAN_VERSION" in
        12) image_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2" ;;
        13) image_url="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
        *)  image_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2" ;;
    esac
    
    log "Downloading Debian ${DEBIAN_VERSION} cloud image..."
    curl -fsSL "$image_url" -o "$image_path"
    
    echo "$image_path"
}

# =============================================================================
# 创建 VM
# =============================================================================
create_vm() {
    local image_path="$1"
    
    log "Creating VM $VMID ($VM_NAME)..."
    
    qm create "$VMID" \
        --name "$VM_NAME" \
        --memory "$MEMORY" \
        --balloon 0 \
        --cores "$CPU_CORES" \
        --cpu host \
        --net0 virtio,bridge="$BRIDGE" \
        --scsihw virtio-scsi-pci \
        --ostype l26 \
        --agent 1 \
        --serial0 socket \
        --vga qxl \
        --hotplug disk,network,usb \
        --onboot 1
    
    log "Importing disk image..."
    local import_output
    import_output=$(qm importdisk "$VMID" "$image_path" "$STORAGE" --format qcow2 2>&1)
    
    local volid
    volid=$(echo "$import_output" | grep -oE "${STORAGE}:[a-zA-Z0-9_/-]+" | head -1 | tr -d "'\"")
    if [[ -z "$volid" ]]; then
        volid="${STORAGE}:vm-${VMID}-disk-0"
    fi
    
    log "Attaching disk to VM..."
    qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$volid"
    qm set "$VMID" --boot order=scsi0
    qm disk resize "$VMID" scsi0 "$DISK_SIZE"
}

# =============================================================================
# 配置 Cloud-Init
# =============================================================================
configure_cloud_init() {
    log "Configuring cloud-init..."
    
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
    
    if [[ -n "$CI_PASSWORD" ]]; then
        qm set "$VMID" --cipassword "$CI_PASSWORD"
    fi
    
    local ssh_key_file=""
    local ssh_keys="$CI_SSH_KEY"
    
    if [[ -n "$CI_PASSWORD" ]]; then
        if [[ -n "$ssh_keys" ]]; then
            info "Password is set, using provided SSH key"
        else
            info "Password authentication enabled, SSH key not configured"
        fi
    else
        if [[ -z "$ssh_keys" && -f "/root/.ssh/id_ed25519.pub" ]]; then
            ssh_keys=$(cat /root/.ssh/id_ed25519.pub)
            info "Using SSH key from /root/.ssh/id_ed25519.pub"
        elif [[ -z "$ssh_keys" && -f "/root/.ssh/id_rsa.pub" ]]; then
            ssh_keys=$(cat /root/.ssh/id_rsa.pub)
            info "Using SSH key from /root/.ssh/id_rsa.pub"
        fi
        
        if [[ -z "$ssh_keys" ]]; then
            warn "No password or SSH key configured! You may not be able to login."
        fi
    fi
    
    if [[ -n "$ssh_keys" ]]; then
        ssh_key_file="/tmp/vm-${VMID}-sshkey.pub"
        echo "$ssh_keys" > "$ssh_key_file"
        chmod 600 "$ssh_key_file"
        qm set "$VMID" --sshkeys "$ssh_key_file"
        rm -f "$ssh_key_file"
        info "SSH key configured"
        SSH_KEY_CONFIGURED=1
    fi
    
    qm set "$VMID" --ciuser "$CI_USER"
    qm set "$VMID" --timezone "$CI_TIMEZONE" 2>/dev/null || true
    
    if [[ "$IP_ADDR" == "dhcp" ]]; then
        qm set "$VMID" --ipconfig0 ip=dhcp
    else
        local ipconfig="ip=${IP_ADDR}"
        [[ -n "$GATEWAY" ]] && ipconfig="${ipconfig},gw=${GATEWAY}"
        qm set "$VMID" --ipconfig0 "$ipconfig"
    fi
    
    if [[ "$IP_ADDR" == "dhcp" ]]; then
        info "DNS will be provided by DHCP server"
    else
        qm set "$VMID" --nameserver "$DNS"
        info "DNS set to $DNS"
    fi
    
    qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1
}

# =============================================================================
# 清理临时镜像
# =============================================================================
cleanup_image() {
    local image_path="$1"
    if [[ -n "${KEEP_IMAGE:-0}" ]]; then
        info "Keeping cloud image at $image_path"
    else
        rm -f "$image_path"
    fi
}

# =============================================================================
# 优化配置
# =============================================================================
configure_optimizations() {
    log "Applying VM optimizations..."
    
    qm set "$VMID" --numa 1
    qm set "$VMID" --scsi0 "$STORAGE:vm-${VMID}-disk-0",cache=writeback,discard=on,ssd=1
    qm set "$VMID" --protection 0
    qm set "$VMID" --description "Debian ${DEBIAN_VERSION} Cloud Image for cyber-claw (XFCE + XRDP + OpenClaw)"
}

# =============================================================================
# 输出连接信息
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo " VM Creation Complete!"
    echo "============================================================================="
    echo ""
    echo " VM ID:       $VMID"
    echo " VM Name:     $VM_NAME"
    echo " OS:          Debian ${DEBIAN_VERSION} (cloud image)"
    echo " CPU:         ${CPU_CORES} cores"
    echo " Memory:      ${MEMORY} MB"
    echo " Disk:        $DISK_SIZE"
    echo " Storage:     $STORAGE"
    echo ""
    echo " Cloud-Init User: $CI_USER"
    [[ -n "$CI_PASSWORD" ]] && echo " Password:    [已设置]"
    [[ "$SSH_KEY_CONFIGURED" -eq 1 ]] && echo " SSH Key:     [已配置]"
    echo ""
    echo "============================================================================="
    echo " Next Steps:"
    echo "============================================================================="
    echo ""
    echo " 1. Start the VM:"
    echo "    qm start $VMID"
    echo ""
    echo " 2. Wait ~90 seconds for cloud-init to complete:"
    echo "    Console: qm terminal $VMID"
    echo ""
    echo " 3. Connect via SSH:"
    echo "    ssh ${CI_USER}@<vm-ip>"
    echo ""
    echo " 4. Install cyber-claw environment:"
    echo "    curl -fsSL https://github.com/riverscn/cyber-claw/raw/main/install-xfce-xrdp-on-debian.sh | bash"
    echo ""
    echo " 5. Install OpenClaw:"
    echo "    curl -fsSL https://openclaw.ai/install.sh | bash"
    echo ""
    echo " 6. Reboot and connect via RDP (port 3389)"
    echo ""
    echo " Tip: Set KEEP_IMAGE=1 to preserve the cloud image for reuse."
    echo "============================================================================="
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    echo ""
    echo "============================================================================="
    echo " PVE Debian Cloud Image VM Creator"
    echo "============================================================================="
    echo ""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vmid) VMID="$2"; shift 2 ;;
            --name) VM_NAME="$2"; shift 2 ;;
            --storage) STORAGE="$2"; shift 2 ;;
            --local-image) LOCAL_IMAGE_PATH="$2"; shift 2 ;;
            --debian-version) DEBIAN_VERSION="$2"; shift 2 ;;
            --disk-size) DISK_SIZE="$2"; shift 2 ;;
            --memory) MEMORY="$2"; shift 2 ;;
            --cpu-cores) CPU_CORES="$2"; shift 2 ;;
            --user) CI_USER="$2"; shift 2 ;;
            --password) CI_PASSWORD="$2"; shift 2 ;;
            --ssh-key) CI_SSH_KEY="$2"; shift 2 ;;
            --bridge) BRIDGE="$2"; shift 2 ;;
            --ip) IP_ADDR="$2"; shift 2 ;;
            --gateway) GATEWAY="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --vmid          VM ID (default: 900)"
                echo "  --name          VM name (default: debian-xfce)"
                echo "  --storage       Storage location (default: local-lvm)"
                echo "  --local-image   Local cloud image path (optional)"
                echo "  --debian-version Debian version 12 or 13 (default: 13)"
                echo "  --disk-size     Disk size (default: 50G)"
                echo "  --memory        Memory in MB (default: 4096)"
                echo "  --cpu-cores     CPU cores (default: 4)"
                echo "  --user          Cloud-init username (default: claw)"
                echo "  --password      Cloud-init password (optional)"
                echo "  --ssh-key       SSH public key (optional)"
                echo "  --bridge        Network bridge (default: vmbr0)"
                echo "  --ip            Static IP or 'dhcp' (default: dhcp)"
                echo "  --gateway       Gateway IP (optional)"
                echo "  -h, --help      Show this help"
                exit 0
                ;;
            *) err "Unknown option: $1" ;;
        esac
    done
    
    check_prerequisites
    
    local image_path
    image_path=$(get_cloud_image)
    
    create_vm "$image_path"
    configure_cloud_init
    configure_optimizations
    cleanup_image "$image_path"
    
    print_summary
}

main "$@"
