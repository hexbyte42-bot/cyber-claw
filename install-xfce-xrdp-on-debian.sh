#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP 全自动安装（OpenClaw 安装前）
# =========================

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
ensure_xrdp_display() {
  local disp out

  # 先从现有会话里找 (Display: :10 紧挨着 User: xxx 的上一行)
  disp="$($SUDO -u "$TARGET_USER" xrdp-sesadmin -c=list 2>/dev/null | awk -v u="$TARGET_USER" '
    $1=="Display:" {d=$2}
    $1=="User:" && $2==u {print d; exit}
  ')"

  if [[ -z "${disp:-}" ]]; then
    # 没有会话就启动一个，并从输出抓 display=:xx
    out="$($SUDO -u "$TARGET_USER" xrdp-sesrun 2>&1 || true)"
    disp="$(echo "$out" | grep -Eo 'display=:[0-9]+' | head -n1 | cut -d= -f2)"
  fi

  if [[ -z "${disp:-}" ]]; then
    warn "Cannot determine XRDP display for $TARGET_USER. xrdp-sesrun output was:"
    echo "$out" | sed 's/^/  /'
    return 1
  fi

  echo "$disp"
}
run_in_xrdp_session() {
  local disp
  disp="$(ensure_xrdp_display)"
  log "Using DISPLAY=$disp for xfconf/xfce4-panel operations"

  # dbus-run-session gives a private session bus so xfconf doesn't need autolaunch
  $SUDO -u "$TARGET_USER" env DISPLAY="$disp" dbus-run-session -- "$@"
}
reload_xfce_panel_real_session() {
  local disp="$1"
  local pid bus

  # 找到该用户的 xfce4-panel 进程
  pid="$(pgrep -u "$TARGET_USER" -x xfce4-panel | head -n1 || true)"

  # 如果没找到 panel，就尝试从 xfce4-session 找 bus
  if [[ -z "${pid:-}" ]]; then
    pid="$(pgrep -u "$TARGET_USER" -x xfce4-session | head -n1 || true)"
  fi

  if [[ -z "${pid:-}" ]]; then
    warn "No xfce4-panel/xfce4-session process found; cannot grab real DBUS_SESSION_BUS_ADDRESS."
    warn "Will try a best-effort restart with DISPLAY only."
    $SUDO -u "$TARGET_USER" env DISPLAY="$disp" nohup xfce4-panel >/dev/null 2>&1 &
    return 0
  fi

  bus="$($SUDO -u "$TARGET_USER" tr '\0' '\n' < "/proc/$pid/environ" \
        | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n1 || true)"

  if [[ -z "${bus:-}" ]]; then
    warn "Could not read DBUS_SESSION_BUS_ADDRESS from /proc/$pid/environ; fallback to DISPLAY-only restart."
    $SUDO -u "$TARGET_USER" env DISPLAY="$disp" nohup xfce4-panel >/dev/null 2>&1 &
    return 0
  fi

  log "Reload panel using real session bus (pid=$pid)"
  # 先尝试 non-blocking restart；不行就 kill + 后台拉起
  if command -v timeout >/dev/null 2>&1; then
    if timeout 3s $SUDO -u "$TARGET_USER" env DISPLAY="$disp" DBUS_SESSION_BUS_ADDRESS="$bus" xfce4-panel --restart >/dev/null 2>&1; then
      return 0
    fi
  else
    $SUDO -u "$TARGET_USER" env DISPLAY="$disp" DBUS_SESSION_BUS_ADDRESS="$bus" xfce4-panel --restart >/dev/null 2>&1 || true
    return 0
  fi

  $SUDO -u "$TARGET_USER" env DISPLAY="$disp" DBUS_SESSION_BUS_ADDRESS="$bus" pkill -x xfce4-panel >/dev/null 2>&1 || true
  $SUDO -u "$TARGET_USER" env DISPLAY="$disp" DBUS_SESSION_BUS_ADDRESS="$bus" nohup xfce4-panel >/dev/null 2>&1 &
}

# 目标用户（写 ~/.config 的那个）
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || err "Cannot determine HOME directory for user: $TARGET_USER"

SUDO="sudo"
[[ "$(id -u)" -eq 0 ]] && SUDO=""

log "Target user: $TARGET_USER"
log "Target HOME: $TARGET_HOME"

log "apt update"
$SUDO apt update

# -------------------------
# XFCE / XRDP
# -------------------------
log "Install XFCE / XRDP / fonts"
$SUDO apt install -y \
  xfce4 xfce4-goodies \
  xrdp xorgxrdp xclip \
  fonts-noto fonts-noto-cjk fonts-noto-color-emoji

$SUDO systemctl enable --now xrdp

# -------------------------
# fcitx5 + Chinese addons
# -------------------------
log "Install fcitx5 + chinese addons"
$SUDO apt install -y --install-recommends fcitx5 fcitx5-chinese-addons

log "Configure fcitx5 profile: ensure pinyin exists (EN system; do NOT change DefaultIM / ordering)"

FCITX_DIR="$TARGET_HOME/.config/fcitx5"
PROFILE="$FCITX_DIR/profile"

$SUDO -u "$TARGET_USER" mkdir -p "$FCITX_DIR"
pkill -x fcitx5 2>/dev/null || true

if [[ ! -f "$PROFILE" ]]; then
  cat > /tmp/fcitx5-profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF
  $SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 /tmp/fcitx5-profile "$PROFILE"
  rm -f /tmp/fcitx5-profile
else
  if ! grep -q '^Name=pinyin$' "$PROFILE"; then
    max="$(grep -Eo '^\[Groups/0/Items/[0-9]+\]$' "$PROFILE" \
      | sed -E 's#.*/([0-9]+)\]#\1#' \
      | sort -n | tail -1)"
    [[ -z "${max:-}" ]] && max=0
    new=$((max + 1))

    cat >> "$PROFILE" <<EOF

[Groups/0/Items/$new]
Name=pinyin
Layout=
EOF
  fi
fi

fcitx5 -rd 2>/dev/null || true

# -------------------------
# Desktop polish
# -------------------------
log "Install Papirus icon theme / global menu / LibreOffice"
$SUDO apt install -y papirus-icon-theme xfce4-appmenu-plugin libreoffice libreoffice-gtk3

# 👉【新增】设置 Papirus 为默认图标主题（XFCE）
log "Set default icon theme to Papirus (ensure XRDP session + DISPLAY + D-Bus)"

run_in_xrdp_session xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus

# -------------------------
# plank-reloaded
# -------------------------
log "Install plank-reloaded"
$SUDO mkdir -p /usr/share/keyrings
curl -fsSL https://zquestz.github.io/ppa/debian/KEY.gpg \
  | $SUDO gpg --dearmor -o /usr/share/keyrings/zquestz-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/zquestz-archive-keyring.gpg] https://zquestz.github.io/ppa/debian ./" \
  | $SUDO tee /etc/apt/sources.list.d/zquestz.list >/dev/null

$SUDO apt update
$SUDO apt install -y plank-reloaded

AUTOSTART="$TARGET_HOME/.config/autostart"
$SUDO -u "$TARGET_USER" mkdir -p "$AUTOSTART"

cat > /tmp/plank.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
OnlyShowIn=XFCE;
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
  /tmp/plank.desktop "$AUTOSTART/plank-reloaded.desktop"
rm -f /tmp/plank.desktop

# -------------------------
# Configure XFCE panel
# -------------------------

log "Configure XFCE panel (remove panel-2, set appmenu as plugin-2, apply settings)"

run_in_xrdp_session bash -lc '
set -euo pipefail

command -v xfconf-query >/dev/null
command -v xfce4-panel  >/dev/null
command -v timeout >/dev/null || { echo "timeout is required (coreutils)."; exit 1; }

set_int_array() {
  local channel="$1"; shift
  local prop="$1"; shift
  local -a vals=("$@")

  local -a args=(--create -c "$channel" -p "$prop")
  local v
  for v in "${vals[@]}"; do
    args+=(-t int -s "$v")
  done
  args+=(-a)
  xfconf-query "${args[@]}"
}

set_string() { xfconf-query --create -c "$1" -p "$2" -t string -s "$3"; }
set_bool()   { xfconf-query --create -c "$1" -p "$2" -t bool   -s "$3"; }

# ---------- 1) Remove panel-2 ----------
PANELS_RAW="$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null || true)"
mapfile -t PANELS_ARR < <(echo "$PANELS_RAW" | tr -cd "0-9 \n" | tr " " "\n" | awk "NF && \$1!=2")
if (( ${#PANELS_ARR[@]} == 0 )); then PANELS_ARR=(1); fi
set_int_array xfce4-panel /panels "${PANELS_ARR[@]}"

# ---------- 2) Force plugin-2 to be appmenu ----------
set_string xfce4-panel /plugins/plugin-2/type appmenu

IDS_RAW="$(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null || true)"
mapfile -t IDS_ARR < <(echo "$IDS_RAW" | tr -cd "0-9 \n" | tr " " "\n" | awk "NF")
mapfile -t IDS_NO2 < <(printf "%s\n" "${IDS_ARR[@]}" | awk "\$1!=2")

if (( ${#IDS_NO2[@]} == 0 )); then
  NEW_IDS=(2)
elif (( ${#IDS_NO2[@]} == 1 )); then
  NEW_IDS=("${IDS_NO2[0]}" 2)
else
  NEW_IDS=("${IDS_NO2[0]}" 2 "${IDS_NO2[@]:1}")
fi

set_int_array xfce4-panel /panels/panel-1/plugin-ids "${NEW_IDS[@]}"

# ---------- 3) appmenu plugin-2 settings ----------
set_bool xfce4-panel /plugins/plugin-2/plugins/plugin-2/bold-application-name true
set_bool xfce4-panel /plugins/plugin-2/plugins/plugin-2/compact-mode          false
'

# ---------- Reload panel (non-blocking + timeout) ----------
echo "Reloading xfce4-panel (non-blocking)..."

DISPLAY_NUM="$(ensure_xrdp_display)"
reload_xfce_panel_real_session "$DISPLAY_NUM"

echo "Done: removed panel-2, forced appmenu on plugin-2, applied settings."

# -------------------------
# openclaw-gateway + xrdp session binding
# -------------------------
log "Configure openclaw-gateway systemd user override"

OVR_DIR="$TARGET_HOME/.config/systemd/user/openclaw-gateway.service.d"
$SUDO -u "$TARGET_USER" mkdir -p "$OVR_DIR"

cat > /tmp/10-xrdp.conf <<EOF
[Service]
ExecStartPre=/usr/bin/bash -c "xrdp-sesadmin -c=list | grep -Eq '^[[:space:]]*User:[[:space:]]*$TARGET_USER\$' || xrdp-sesrun"
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
  /tmp/10-xrdp.conf "$OVR_DIR/10-xrdp.conf"
rm -f /tmp/10-xrdp.conf

$SUDO systemctl daemon-reload

log "Configure XFCE autostart: restart openclaw-gateway after login"

cat > /tmp/restart-openclaw.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Restart OpenClaw Gateway
Exec=/usr/bin/bash -lc "xrdp-sesadmin -c=list | grep -Eq '^[[:space:]]*User:[[:space:]]*$TARGET_USER\$' && openclaw gateway restart || true"
X-GNOME-Autostart-enabled=true
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
  /tmp/restart-openclaw.desktop "$AUTOSTART/restart-openclaw-gateway.desktop"
rm -f /tmp/restart-openclaw.desktop

sudo systemctl disable --now lightdm

# -------------------------
# Finish: hand back to user
# -------------------------
warn "System is ready. Final step (OpenClaw install) is manual:"
cat <<'EOF'

============================================================
curl -fsSL https://openclaw.ai/install.sh | bash
============================================================

EOF
