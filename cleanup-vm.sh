#!/bin/bash
# =============================================================================
# VM Internal Cleanup Script
# 虚拟机内部清理脚本 - 用于导出模板前清理系统
# =============================================================================
# 
# 使用方法:
#   1. 直接运行：./cleanup-vm.sh
#   2. 或通过 qm guest exec 执行
#
# 清理内容:
#   - APT 缓存和自动删除的包
#   - 临时文件 (/tmp, /var/tmp)
#   - 日志文件
#   - 用户缓存
#   - Shell 历史
#   - WPS Office 缓存
#   - OpenClaw 配置
#   - Journal 日志
#   - SSH host keys (安全重置)
#   - machine-id (避免克隆冲突)
#   - cloud-init 数据 (确保下次启动重新初始化)
#   - 磁盘空间归零 (便于压缩)
# =============================================================================

# 不设置 set -e，每个命令自行处理错误
# set -e  # Removed - we handle errors per-command

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
info() { printf "${BLUE}[i]${NC} %s\n" "$*"; }

# =============================================================================
# 前置检查
# =============================================================================
check_prerequisites() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must run as root"
    fi
    log "Running as root - proceeding with cleanup"
}

info "=== VM Internal Cleanup Script ==="
info "Starting cleanup at $(date)"
echo ""

# Run prerequisites
check_prerequisites

# =============================================================================
# 1. APT 清理
# =============================================================================
log "Cleaning apt cache..."
apt-get clean || warn "apt-get clean failed"
apt-get autoremove -y || warn "apt-get autoremove failed"
rm -rf /var/cache/apt/archives/*.deb || true
info "  - APT cache cleaned"

# =============================================================================
# 2. 临时文件清理
# =============================================================================
log "Cleaning temporary files..."
rm -rf /tmp/* || true
rm -rf /var/tmp/* || true
info "  - Temporary files cleaned"

# =============================================================================
# 3. 日志文件清理
# =============================================================================
log "Cleaning log files..."
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
rm -f /var/log/*.gz || true
rm -f /var/log/*.[0-9] || true
info "  - Log files cleaned"

# =============================================================================
# 4. 用户缓存清理
# =============================================================================
log "Cleaning user caches..."
for user_home in /home/*; do
    if [[ -d "$user_home/.cache" ]]; then
        rm -rf "$user_home/.cache"/* || true
        info "  - Cleaned $user_home/.cache"
    fi
done

# =============================================================================
# 5. Shell 历史清理
# =============================================================================
log "Cleaning shell history..."
for user_home in /home/* /root; do
    rm -f "$user_home/.bash_history" || true
    rm -f "$user_home/.history" || true
    rm -f "$user_home/.sh_history" || true
    rm -f "$user_home/.zsh_history" || true
done
info "  - Shell history cleaned"

# =============================================================================
# 6. WPS Office 缓存清理
# =============================================================================
log "Cleaning WPS Office cache..."
for user_home in /home/*; do
    rm -rf "$user_home/.wps-office" || true
    info "  - Cleaned $user_home/.wps-office"
done

# =============================================================================
# 7. OpenClaw 配置清理
# =============================================================================
log "Cleaning OpenClaw configuration..."
rm -rf /root/.openclaw || true
for user_home in /home/*; do
    rm -rf "$user_home/.openclaw" || true
done
info "  - OpenClaw configuration cleaned"

# =============================================================================
# 8. Journal 日志清理
# =============================================================================
log "Cleaning journal logs..."
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/journal/* 2>/dev/null || true
info "  - Journal logs cleaned"

# =============================================================================
# 9. SSH Host Keys 清理 (安全重置)
# =============================================================================
log "Cleaning SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true
info "  - SSH host keys removed (will regenerate on next boot)"

# =============================================================================
# 10. machine-id 重置 (避免克隆 VM 冲突)
# =============================================================================
log "Resetting machine-id..."
if [[ -f /etc/machine-id ]]; then
    truncate -s 0 /etc/machine-id || true
    info "  - machine-id reset"
else
    warn "  - /etc/machine-id not found"
fi

# =============================================================================
# 11. cloud-init 数据清理 (确保下次启动重新初始化)
# =============================================================================
log "Cleaning cloud-init data..."
rm -rf /var/lib/cloud/instances/* || true
rm -rf /var/lib/cloud/instance || true
rm -f /var/lib/cloud/.instance-id || true
rm -rf /var/log/cloud-init* || true
info "  - cloud-init data cleaned"

# =============================================================================
# 12. 其他系统缓存
# =============================================================================
log "Cleaning other system caches..."
rm -rf /var/cache/fontconfig/* 2>/dev/null || true
rm -rf /root/.cache 2>/dev/null || true
info "  - System caches cleaned"

# =============================================================================
# 13. 磁盘空间归零 (便于压缩)
# =============================================================================
log "Zeroing free space (this may take a while)..."
info "  - Writing zeros to /zerofile..."
dd if=/dev/zero of=/zerofile bs=1M status=none 2>/dev/null || true
sync
info "  - Removing zerofile..."
rm -f /zerofile || true  # Ensure cleanup even if dd partially failed
info "  - Free space zeroed"

# =============================================================================
# 完成
# =============================================================================
echo ""
log "=== Cleanup Complete ==="
info "Finished at $(date)"
echo ""
info "VM is now ready for export."
