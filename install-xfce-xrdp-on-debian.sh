#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP automated setup (before installing OpenClaw)
# =========================

# Proxy support - REQUIRED for all network access
# These variables must be set before running this script
if [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
    err "http_proxy or https_proxy environment variable must be set. This machine cannot access the internet directly."
fi

export http_proxy="${http_proxy}"
export https_proxy="${https_proxy}"
export HTTP_PROXY="${http_proxy}"
export HTTPS_PROXY="${https_proxy}"

# Export for sudo commands
export SUDO_HTTP_PROXY="$HTTPS_PROXY"
export SUDO_HTTPS_PROXY="$HTTPS_PROXY"

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
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

  # User session bus path is usually stable even when XFCE processes are not up yet.
  bus_path="/run/user/${uid}/bus"
  if [[ -S "$bus_path" ]]; then
    SESSION_DBUS="unix:path=$bus_path"
  fi

  # Prefer XRDP display when available for this target user.
  SESSION_DISPLAY="$(latest_xrdp_display)"

  # Fallback: sniff any DISPLAY from user's session-related processes.
  if [[ -z "${SESSION_DISPLAY:-}" ]]; then
    for p in $(pgrep -u "$uid" -f 'dbus-daemon|dbus-broker|xfce4-session|xfconfd|xfce4-panel|Xorg|Xwayland' 2>/dev/null || true); do
      [[ -r "/proc/$p/environ" ]] || continue
      env_display="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^DISPLAY=//p' | head -n1)"
      [[ -n "${env_display:-}" ]] || continue
      SESSION_DISPLAY="$env_display"
      break
    done
  fi

  # If bus wasn't from /run/user/<uid>/bus, try extracting from process env.
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
  local out disp

  if [[ -n "${SESSION_DISPLAY:-}" && -n "${SESSION_DBUS:-}" ]]; then
    return 0
  fi

  # First, try to reuse an existing graphical session context (physical or XRDP).
  log "Detecting existing graphical session context (DISPLAY + DBUS)..."
  if find_session_context; then
    log "Found existing session context: DISPLAY=$SESSION_DISPLAY"
    return 0
  fi

  # If no session context exists, start XRDP session then detect its context.
  log "No session context found. Starting XRDP session and re-detecting context..."
  out="$(run_as_user "$TARGET_USER" xrdp-sesrun 2>&1 || true)"
  disp="$(echo "$out" | grep -Eo 'display=:[0-9]+' | head -n1 | cut -d= -f2)"
  if [[ -n "${disp:-}" ]]; then
    SESSION_DISPLAY="$disp"
  fi

  if find_session_context; then
    log "XRDP session context ready: DISPLAY=$SESSION_DISPLAY"
    return 0
  fi

  log "Waiting for XRDP session context to become ready..."
  for _ in {1..30}; do
    sleep 1
    if find_session_context; then
      log "XRDP session context ready after wait: DISPLAY=$SESSION_DISPLAY"
      return 0
    fi
  done

  warn "Cannot determine graphical session context for $TARGET_USER. xrdp-sesrun output was:"
  printf '  %s\n' "$out"
  return 1
}

run_in_session_context() {
  ensure_session_context
  log "Using DISPLAY=$SESSION_DISPLAY DBUS_SESSION_BUS_ADDRESS=$SESSION_DBUS for xfconf/xfce4-panel operations"
  run_as_user "$TARGET_USER" env DISPLAY="$SESSION_DISPLAY" DBUS_SESSION_BUS_ADDRESS="$SESSION_DBUS" "$@"
}

# Optional flags
APT_QUIET=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --quiet)
      APT_QUIET=1
      ;;
    -h|--help)
      echo "Usage: $0 [--quiet]"
      echo ""
      echo "Environment variables (REQUIRED):"
      echo "  http_proxy   Proxy URL (e.g., http://proxy.example.com:8080)"
      echo "  https_proxy  Proxy URL (e.g., http://proxy.example.com:8080)"
      echo ""
      echo "Example:"
      echo "  export http_proxy=http://proxy.example.com:8080"
      echo "  export https_proxy=http://proxy.example.com:8080"
      echo "  sudo -E bash $0"
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
fi

# Target user (the one whose ~/.config will be written)
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || err "Cannot determine HOME directory for user: $TARGET_USER"

SUDO="sudo"
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || err "sudo is required"
fi

# Preserve proxy environment for sudo commands
if [[ "$(id -u)" -ne 0 ]]; then
    # Check if proxy variables are preserved in sudo
    if ! sudo env | grep -q "http_proxy"; then
        log "Configuring sudo to preserve proxy environment..."
        # Add env_keep for proxy variables if not already present
        if ! grep -q "http_proxy" /etc/sudoers.d/proxy_env 2>/dev/null; then
            cat > /etc/sudoers.d/proxy_env << 'EOF'
Defaults env_keep += "http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY"
EOF
            chmod 440 /etc/sudoers.d/proxy_env
            log "Sudo proxy environment configured"
        fi
    fi
fi

run_as_user() {
  local user="$1"
  shift
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$user" -- "$@"
  else
    sudo -u "$user" "$@"
  fi
}

log "Target user: $TARGET_USER"
log "Target HOME: $TARGET_HOME"

# Helper function to run commands with proxy environment for sudo
run_with_proxy() {
    local proxy_vars="http_proxy=$http_proxy https_proxy=$https_proxy HTTP_PROXY=$HTTP_PROXY HTTPS_PROXY=$HTTPS_PROXY"
    if [[ "$(id -u)" -eq 0 ]]; then
        eval $proxy_vars "$@"
    else
        sudo env $proxy_vars "$@"
    fi
}

apt_run() {
    local proxy_vars="http_proxy=$http_proxy https_proxy=$https_proxy HTTP_PROXY=$HTTP_PROXY HTTPS_PROXY=$HTTPS_PROXY"
    
    if [[ "$APT_QUIET" == "1" ]]; then
        if [[ -n "$SUDO" ]]; then
            $SUDO env $proxy_vars DEBIAN_FRONTEND=noninteractive \
                apt-get -q -y \
                -o Dpkg::Use-Pty=0 \
                -o Dpkg::Progress-Fancy=0 \
                "$@"
        else
            env $proxy_vars DEBIAN_FRONTEND=noninteractive \
                apt-get -q -y \
                -o Dpkg::Use-Pty=0 \
                -o Dpkg::Progress-Fancy=0 \
                "$@"
        fi
    else
        $SUDO env $proxy_vars DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
    fi
}

log "apt-get update"
apt_run update

# -------------------------
# XFCE / XRDP
# -------------------------
log "Install XFCE / XRDP / fonts"
apt_run install -y \
  xfce4 xfce4-goodies \
  xrdp xorgxrdp xclip xserver-xorg-input-libinput \
  pipewire-audio pipewire-module-xrdp \
  fonts-noto fonts-noto-cjk fonts-noto-color-emoji

$SUDO systemctl enable --now xrdp
$SUDO systemctl disable lightdm

# -------------------------
# fcitx5 + Chinese addons
# -------------------------
log "Install fcitx5 + chinese addons"
apt_run install -y --install-recommends fcitx5 fcitx5-chinese-addons

log "Configure fcitx5 profile: ensure pinyin exists (EN system; do NOT change DefaultIM / ordering)"

FCITX_DIR="$TARGET_HOME/.config/fcitx5"
PROFILE="$FCITX_DIR/profile"

run_as_user "$TARGET_USER" mkdir -p "$FCITX_DIR"
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
log "Install Papirus icon theme / global menu / WPS Office / Chromium"
apt_run install -y papirus-icon-theme xfce4-appmenu-plugin chromium

# Install WPS Office
log "Install WPS Office"
WPS_DEB_URL="https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office_11.1.0.11723.XA_amd64.deb"
WPS_DEB="/tmp/wps-office.deb"

# Download with proxy (try with proxy first, fallback to direct)
log "Downloading WPS Office (with proxy: $http_proxy)..."
if curl --proxy "$http_proxy" -fsSL "$WPS_DEB_URL" -o "$WPS_DEB" 2>/dev/null; then
    log "Downloaded WPS Office via proxy"
elif curl -fsSL "$WPS_DEB_URL" -o "$WPS_DEB" 2>/dev/null; then
    log "Downloaded WPS Office (direct)"
else
    err "Failed to download WPS Office. Check your proxy settings."
fi

if [[ -f "$WPS_DEB" ]]; then
    # Install with proxy for potential dependency downloads
    run_with_proxy dpkg -i "$WPS_DEB" || run_with_proxy apt-get install -f -y
    rm -f "$WPS_DEB"
    log "WPS Office installed successfully"
else
    err "WPS Office download failed"
fi

# Set Papirus as the default icon theme (XFCE)
log "Set default icon theme to Papirus"
run_in_session_context xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus

# -------------------------
# plank-reloaded
# -------------------------
log "Install plank-reloaded"
$SUDO mkdir -p /usr/share/keyrings

# Download GPG key with proxy
if curl --proxy "$http_proxy" -fsSL https://zquestz.github.io/ppa/debian/KEY.gpg -o /tmp/zquestz-key.gpg 2>/dev/null || \
   curl -fsSL https://zquestz.github.io/ppa/debian/KEY.gpg -o /tmp/zquestz-key.gpg; then
    $SUDO gpg --dearmor -o /usr/share/keyrings/zquestz-archive-keyring.gpg /tmp/zquestz-key.gpg
    rm -f /tmp/zquestz-key.gpg
else
    err "Failed to download plank-reloaded GPG key"
fi

# Add repository
echo "deb [signed-by=/usr/share/keyrings/zquestz-archive-keyring.gpg] https://zquestz.github.io/ppa/debian ./" \
  | $SUDO tee /etc/apt/sources.list.d/zquestz.list >/dev/null

apt_run update
apt_run install -y plank-reloaded

AUTOSTART="$TARGET_HOME/.config/autostart"
run_as_user "$TARGET_USER" mkdir -p "$AUTOSTART"

log "Configure XFCE panel (remove panel-2, set appmenu as plugin-2, apply settings)"

# 1) delete panel-2 by keeping only panel-1
run_in_session_context xfconf-query --create -c xfce4-panel -p /panels -t int -s 1 -a

# 2) force plugin-2 to be appmenu (NOTE: your system stores type at /plugins/plugin-2)
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2 -t string -s appmenu

# 3) appmenu settings
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/bold-application-name -t bool -s true
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/compact-mode -t bool -s false
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-2/plugins/plugin-2/expand -t bool -s false
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/button-icon -t string -s xfce4_xicon2
run_in_session_context xfconf-query --create -c xfce4-panel -p /plugins/plugin-1/show-button-title -t bool -s false
run_in_session_context xfce4-panel -r || true

# 4) apply dock changes now
run_in_session_context plank >/dev/null 2>&1 &
# -------------------------
# openclaw-gateway + xrdp session binding
# -------------------------
log "Configure openclaw-gateway systemd user override"

OVR_DIR="$TARGET_HOME/.config/systemd/user/openclaw-gateway.service.d"
run_as_user "$TARGET_USER" mkdir -p "$OVR_DIR"

cat > /tmp/10-xrdp.conf <<EOF
[Service]
ExecStartPre=/usr/bin/bash -c "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!="") exit 0; exit 1}' || xrdp-sesrun"
EOF

$SUDO install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
  /tmp/10-xrdp.conf "$OVR_DIR/10-xrdp.conf"
rm -f /tmp/10-xrdp.conf

$SUDO systemctl daemon-reload

log "Configure XFCE autostart: restart openclaw-gateway after login"

cat > "$AUTOSTART/restart-openclaw-gateway.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Restart OpenClaw Gateway
Exec=/usr/bin/bash -lc "xrdp-sesadmin -c=list 2>/dev/null | awk -v u='$TARGET_USER' '\$1==\"Display:\" {d=\$2} \$1==\"User:\" && \$2==u {last=d} END {if (last!="") exit 0; exit 1}' && openclaw gateway restart || true"
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

run_as_user "$TARGET_USER" test -s "$AUTOSTART/restart-openclaw-gateway.desktop" || err "restart-openclaw-gateway.desktop is empty"
run_as_user "$TARGET_USER" test -s "$AUTOSTART/plank-reloaded.desktop" || err "plank autostart desktop file is empty at finish"

# logout step disabled
# if [[ -n "$(latest_xrdp_display)" ]]; then
#   log "Logging out current desktop session(s) for $TARGET_USER"
#
#   # Find loginctl session id that belongs to this user and XRDP display.
#   sid=""
#   for candidate in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$TARGET_USER" '$3==u {print $1}'); do
#     display="$(loginctl show-session "$candidate" -p Display --value 2>/dev/null || true)"
#     if [[ "$display" == "$(latest_xrdp_display)" ]]; then
#       sid="$candidate"
#       break
#     fi
#   done
#
#   if [[ -n "${sid:-}" ]]; then
#     loginctl terminate-session "$sid" || true
#   else
#     warn "No matching loginctl XRDP session found for DISPLAY=$(latest_xrdp_display); skip logout step."
#   fi
# else
#   warn "No XRDP session found for $TARGET_USER; skip logout step."
# fi

warn "Setup finished. Please connect again via your XRDP client / remote desktop tool to enter the configured XFCE session."
warn "Then install OpenClaw manually: curl -fsSL https://openclaw.ai/install.sh | bash"
