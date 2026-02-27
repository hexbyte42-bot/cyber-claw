#!/bin/bash
# 修复 VM 900 启动卡住问题

VMID=900

echo "=== 修复 VM $VMID ==="
echo ""

echo "[1/4] Stopping VM..."
qm stop $VMID --timeout 10 || qm shutdown $VMID || true
sleep 2

echo "[2/4] Changing VGA to std..."
qm set $VMID --vga std

echo "[3/4] Adding tablet device for better mouse support..."
qm set $VMID --tablet 1

echo "[4/4] Setting keyboard layout..."
qm set $VMID --keyboard en-us

echo ""
echo "=== 修复完成 ==="
echo ""
echo "现在启动 VM:"
echo "  qm start $VMID"
echo ""
echo "然后使用控制台查看（按 Ctrl+C 退出控制台）:"
echo "  qm terminal $VMID"
echo ""
echo "如果还是卡住，等待 2-3 分钟让 cloud-init 完成初始化"
