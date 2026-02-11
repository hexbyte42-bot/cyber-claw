#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP automated setup (before installing OpenClaw)
# =========================

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
ensure_xrdp_display() {
  local disp out

  # Try to find an existing session first (Display: :10 appears right above User: xxx)
  disp="$($SUDO -u "$TARGET_USER" xrdp-sesadmin -c=list 2>/dev/null | awk -v u="$TARGET_USER" '
    $1=="Display:" {d=$2}
    $1=="User:" && $2==u {print d; exit}
  ')"

  if [[ -z "${disp:-}" ]]; then
    # No session found: start one and parse display=:xx from the output
    out="$($SUDO -u "$TARGET_USER" xrdp-sesrun 2>&1 || true)"
    disp="$(echo "$out" | grep -Eo 'display=:[0-9]+' | head -n1 | cut -d= -f2)"
  fi

  if [[ -z "${disp:-}" ]]; then
    warn "Cannot determine XRDP display for $TARGET_USER. xrdp-sesrun output was:"
    printf '  %s\n' "$out"
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

# Target user (the one whose ~/.config will be written)
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
log "Install Papirus icon theme / global menu / LibreOffice / Chromium"
$SUDO apt install -y papirus-icon-theme xfce4-appmenu-plugin libreoffice libreoffice-gtk3 chromium

# Set Papirus as the default icon theme (XFCE)
log "Set default icon theme to Papirus (ensure XRDP session + DISPLAY + D-Bus)"

DISPLAY_NUM="$(ensure_xrdp_display)"
log "Using DISPLAY=$DISPLAY_NUM"

# dbus-run-session is more reliable than dbus-launch: it provides a temporary session bus for this command
$SUDO -u "$TARGET_USER" env DISPLAY="$DISPLAY_NUM" dbus-run-session -- \
  xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus

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

log "Configure XFCE panel (remove panel-2, set appmenu as plugin-2, apply settings)"

# shellcheck disable=SC2016
run_in_xrdp_session bash -lc '
set -euo pipefail
command -v xfconf-query >/dev/null
command -v xfce4-panel  >/dev/null
command -v timeout >/dev/null

set_int_array() {
  local channel="$1"; shift
  local prop="$1"; shift
  local -a vals=("$@")
  local -a args=(--create -c "$channel" -p "$prop")
  for v in "${vals[@]}"; do
    args+=(-t int -s "$v")
  done
  args+=(-a)
  xfconf-query "${args[@]}"
}

set_string(){ xfconf-query --create -c "$1" -p "$2" -t string -s "$3"; }
set_bool(){   xfconf-query --create -c "$1" -p "$2" -t bool   -s "$3"; }

# 1) delete panel-2 by keeping only panel-1
set_int_array xfce4-panel /panels 1

# 2) force plugin-2 to be appmenu (NOTE: your system stores type at /plugins/plugin-2)
set_string xfce4-panel /plugins/plugin-2 appmenu

# 3) appmenu settings
set_bool xfce4-panel /plugins/plugin-2/plugins/plugin-2/bold-application-name true
set_bool xfce4-panel /plugins/plugin-2/plugins/plugin-2/compact-mode          false
'

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

$SUDO systemctl disable --now lightdm

# -------------------------
# Finish: hand back to user
# -------------------------
warn "System is ready. Final step (OpenClaw install) is manual:"
cat <<'EOF'

============================================================
curl -fsSL https://openclaw.ai/install.sh | bash
============================================================

EOF

if [[ -t 0 ]]; then
  read -r -p "Reboot now to apply all changes? [y/N]: " reboot_ans
  case "${reboot_ans,,}" in
    y|yes)
      log "Rebooting system now..."
      $SUDO reboot
      ;;
    *)
      warn "Reboot skipped. Please reboot manually when convenient."
      ;;
  esac
else
  warn "Non-interactive shell detected; skipping reboot prompt."
  warn "Please reboot manually to apply all changes."
fi
