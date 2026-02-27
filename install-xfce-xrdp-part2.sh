#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP automated setup - Part 2 (GUI Configuration)
# =========================

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || err "Cannot determine HOME directory"

SUDO="sudo"
[[ "$(id -u)" -eq 0 ]] && SUDO=""

run_as_user() {
    local user="$1"; shift
    if [[ "$(id -u)" -eq 0 ]]; then
        runuser -u "$user" -- "$@"
    else
        sudo -u "$user" "$@"
    fi
}

log "=== Part 2: XFCE Configuration ==="

# Session context detection
SESSION_DISPLAY=""
SESSION_DBUS=""

latest_xrdp_display() {
  run_as_user "$TARGET_USER" xrdp-sesadmin -c=list 2>/dev/null | awk -v u="$TARGET_USER" '
    $1=="Display:" {d=$2}
    $1=="User:" && $2==u {last=d}
    END {print last}
  '
}

find_session_context() {
  local uid p env_display env_bus bus_path
  uid="$(id -u "$TARGET_USER")"

  bus_path="/run/user/${uid}/bus"
  [[ -S "$bus_path" ]] && SESSION_DBUS="unix:path=$bus_path"

  SESSION_DISPLAY="$(latest_xrdp_display)"

  if [[ -z "${SESSION_DISPLAY:-}" ]]; then
    for p in $(pgrep -u "$uid" -f 'dbus-daemon|dbus-broker|xfce4-session|xfconfd|xfce4-panel|Xorg|Xwayland' 2>/dev/null || true); do
      [[ -r "/proc/$p/environ" ]] || continue
      env_display="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^DISPLAY=//p' | head -n1)"
      [[ -n "${env_display:-}" ]] || continue
      SESSION_DISPLAY="$env_display"
      break
    done
  fi

  if [[ -z "${SESSION_DBUS:-}" ]]; then
    for p in $(pgrep -u "$uid" -f 'dbus-daemon|dbus-broker|xfce4-session|xfconfd|xfce4-panel' 2>/dev/null || true); do
      [[ -r "/proc/$p/environ" ]] || continue
      env_bus="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n1)"
      [[ -n "${env_bus:-}" ]] || continue
      SESSION_DBUS="$env_bus"
      break
    done
  fi

  [[ -n "${SESSION_DISPLAY:-}" && -n "${SESSION_DBUS:-}" ]]
}

ensure_session_context() {
  if [[ -n "${SESSION_DISPLAY:-}" && -n "${SESSION_DBUS:-}" ]]; then
    return 0
  fi

  log "Starting XRDP session..."
  run_as_user "$TARGET_USER" xrdp-sesrun >/dev/null 2>&1 || true
  
  log "Waiting for XRDP session to initialize (15 seconds)..."
  sleep 15

  if find_session_context; then
    log "XRDP session ready: DISPLAY=$SESSION_DISPLAY"
    return 0
  fi

  log "Waiting for session context..."
  for _ in {1..30}; do
    sleep 1
    if find_session_context; then
      log "Session context ready: DISPLAY=$SESSION_DISPLAY"
      return 0
    fi
  done

  warn "Cannot determine session context, continuing anyway..."
  return 1
}

run_in_session_context() {
  ensure_session_context || return 1
  local display_with_screen="$SESSION_DISPLAY"
  [[ ! "$SESSION_DISPLAY" =~ \.[0-9]+$ ]] && display_with_screen="${SESSION_DISPLAY}.0"
  log "Using DISPLAY=$display_with_screen"
  run_as_user "$TARGET_USER" env DISPLAY="$display_with_screen" DBUS_SESSION_BUS_ADDRESS="$SESSION_DBUS" "$@"
}

# Set icon theme
log "Set default icon theme to Papirus"
run_in_session_context xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus || \
  warn "Failed to set icon theme"

# XFCE Panel Configuration
AUTOSTART="$TARGET_HOME/.config/autostart"
run_as_user "$TARGET_USER" mkdir -p "$AUTOSTART"

log "Configure XFCE panel"

timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /panels -t int -s 1 -a || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2 -t string -s appmenu || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/bold-application-name -t bool -s true || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/compact-mode -t bool -s false || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/expand -t bool -s false || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/button-icon -t string -s xfce4_xicon2 || true
timeout 5 run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/show-button-title -t bool -s false || true

log "Restarting XFCE panel..."
run_in_session_context timeout 3 xfce4-panel -r || warn "Panel restart failed (will restart after login)"

log "Starting plank dock..."
run_in_session_context timeout 3 plank >/dev/null 2>&1 &

# Configure plank to never hide (fix: dock disappears when window maximized)
log "Configuring plank dock settings..."
PLANK_CONFIG_DIR="$TARGET_HOME/.config/plank/dock1"
run_as_user "$TARGET_USER" mkdir -p "$PLANK_CONFIG_DIR"
cat > "$PLANK_CONFIG_DIR/settings" <<'EOF'
[plank]
current-theme=default
icon-size=48
zoom-enabled=true
zoom-percent=1.25
hide-mode=0
pressure-reveal-enabled=false
hide-delay=0
unhide-delay=0
reveal-pressure=10
monitor=0
alignment=center
items=['firefox.desktop', 'thunar.desktop', 'xfce4-terminal.desktop', 'xfce4-settings-manager.desktop']
EOF
$SUDO chown -R "$TARGET_USER:$TARGET_USER" "$PLANK_CONFIG_DIR"
log "Plank configured: hide-mode=0 (never hide)"

# OpenClaw Gateway Configuration
log "Configure openclaw-gateway systemd user override"

OVR_DIR="$TARGET_HOME/.config/systemd/user/openclaw-gateway.service.d"
run_as_user "$TARGET_USER" mkdir -p "$OVR_DIR"

cat > /tmp/10-xrdp.conf <<EOF
[Service]
ExecStartPre=/usr/bin/bash -c "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!=\"\") exit 0; exit 1}' || xrdp-sesrun"
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 /tmp/10-xrdp.conf "$OVR_DIR/10-xrdp.conf"
rm -f /tmp/10-xrdp.conf
$SUDO systemctl daemon-reload

log "Configure XFCE autostart"

cat > "$AUTOSTART/restart-openclaw-gateway.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Restart OpenClaw Gateway
Exec=/usr/bin/bash -lc "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!=\"\") exit 0; exit 1}' && openclaw gateway restart || true"
X-GNOME-Autostart-enabled=true
EOF
$SUDO chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART/restart-openclaw-gateway.desktop"
$SUDO chmod 0644 "$AUTOSTART/restart-openclaw-gateway.desktop"

cat > "$AUTOSTART/plank-reloaded.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
OnlyShowIn=XFCE;
EOF
$SUDO chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART/plank-reloaded.desktop"
$SUDO chmod 0644 "$AUTOSTART/plank-reloaded.desktop"

log "=== Part 2 Complete ==="
echo ""
echo "============================================================================="
echo " XFCE configuration complete!"
echo "============================================================================="
echo ""
echo " Next steps:"
echo "  1. Install OpenClaw:"
echo "     curl -fsSL https://openclaw.ai/install.sh | bash"
echo ""
echo "  2. Reboot and connect via RDP (port 3389)"
echo ""
echo "============================================================================="
