#!/usr/bin/env bash
set -euo pipefail

# =========================
# Debian + XFCE + XRDP automated setup - Part 1 (System Installation)
# =========================

USE_PROXY="${USE_PROXY:-false}"
PROXY_CONFIGURED=false

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }

setup_proxy() {
    if [[ "$USE_PROXY" == "true" || "$USE_PROXY" == "1" || "$USE_PROXY" == "yes" ]]; then
        if [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
            err "USE_PROXY=true but http_proxy/https_proxy not set."
        fi
        export http_proxy="${http_proxy}"
        export https_proxy="${https_proxy}"
        export HTTP_PROXY="${http_proxy}"
        export HTTPS_PROXY="${https_proxy}"
        PROXY_CONFIGURED=true
        log "Proxy enabled: $http_proxy"
        
        if [[ "$(id -u)" -ne 0 ]]; then
            if ! grep -q "http_proxy" /etc/sudoers.d/proxy_env 2>/dev/null; then
                cat > /etc/sudoers.d/proxy_env << 'EOF'
Defaults env_keep += "http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY"
EOF
                chmod 440 /etc/sudoers.d/proxy_env
                log "Sudo proxy environment configured"
            fi
        fi
    else
        log "Proxy not enabled"
    fi
}

run_with_proxy() {
    if [[ "$PROXY_CONFIGURED" == "true" ]]; then
        local proxy_vars="http_proxy=$http_proxy https_proxy=$https_proxy HTTP_PROXY=$HTTP_PROXY HTTPS_PROXY=$HTTPS_PROXY"
        if [[ "$(id -u)" -eq 0 ]]; then
            eval $proxy_vars "$@"
        else
            sudo env $proxy_vars "$@"
        fi
    else
        "$@"
    fi
}

apt_run() {
    if [[ "$PROXY_CONFIGURED" == "true" ]]; then
        local proxy_vars="http_proxy=$http_proxy https_proxy=$https_proxy HTTP_PROXY=$HTTP_PROXY HTTPS_PROXY=$HTTPS_PROXY"
        $SUDO env $proxy_vars DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
            apt-get \
            -o Acquire::http::Proxy="$http_proxy" \
            -o Acquire::https::Proxy="$https_proxy" \
            "$@"
    else
        $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
    fi
}

curl_with_proxy() {
    if [[ "$PROXY_CONFIGURED" == "true" ]]; then
        curl --proxy "$http_proxy" "$@"
    else
        curl "$@"
    fi
}

APT_QUIET=0
if [[ $# -gt 0 ]]; then
    case "$1" in
        --quiet) APT_QUIET=1 ;;
        --use-proxy=*) USE_PROXY="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: \$0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --use-proxy=true|false  Enable proxy (default: false)"
            echo "  --quiet                 Quiet mode"
            echo "  -h, --help              Show help"
            exit 0
            ;;
        *) err "Unknown argument: $1" ;;
    esac
fi

setup_proxy

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

log "Target user: $TARGET_USER"

# =========================
# Package Installation
# =========================
log "=== Part 1: System Installation ==="
log "apt-get update"
apt_run update

log "Install XFCE / XRDP / fonts / dbus-x11"
apt_run install -y \
    xfce4 xfce4-goodies \
    xrdp xorgxrdp xclip xserver-xorg-input-libinput \
    pipewire-audio pipewire-module-xrdp \
    fonts-noto fonts-noto-cjk fonts-noto-color-emoji \
    dbus-x11

$SUDO systemctl enable --now xrdp
$SUDO systemctl disable lightdm

log "Install fcitx5 + chinese addons"
apt_run install -y --install-recommends fcitx5 fcitx5-chinese-addons

log "Configure fcitx5 profile"
FCITX_DIR="$TARGET_HOME/.config/fcitx5"
PROFILE="$FCITX_DIR/profile"
run_as_user "$TARGET_USER" mkdir -p "$FCITX_DIR"

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
fi

log "Install Papirus icon theme / Chromium"
apt_run install -y papirus-icon-theme xfce4-appmenu-plugin chromium

log "Install WPS Office"
WPS_DEB_URL="https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office_11.1.0.11723.XA_amd64.deb"
WPS_DEB="/tmp/wps-office.deb"

if curl_with_proxy -fsSL --max-time 300 --retry 3 "$WPS_DEB_URL" -o "$WPS_DEB" 2>/dev/null; then
    if [[ -f "$WPS_DEB" && -s "$WPS_DEB" ]]; then
        run_with_proxy dpkg -i "$WPS_DEB" || run_with_proxy apt-get install -f -y
        rm -f "$WPS_DEB"
        log "WPS Office installed"
    else
        err "WPS download failed (empty file)"
    fi
else
    if curl -fsSL --max-time 300 --retry 3 "$WPS_DEB_URL" -o "$WPS_DEB" 2>/dev/null; then
        if [[ -f "$WPS_DEB" && -s "$WPS_DEB" ]]; then
            dpkg -i "$WPS_DEB" || apt-get install -f -y
            rm -f "$WPS_DEB"
            log "WPS Office installed (direct)"
        else
            err "WPS download failed"
        fi
    else
        err "Failed to download WPS Office"
    fi
fi

log "Install plank-reloaded"
$SUDO mkdir -p /usr/share/keyrings

if curl_with_proxy -fsSL --max-time 30 --retry 3 \
    https://zquestz.github.io/ppa/debian/KEY.gpg -o /tmp/zquestz-key.gpg 2>/dev/null; then
    $SUDO gpg --dearmor -o /usr/share/keyrings/zquestz-archive-keyring.gpg /tmp/zquestz-key.gpg
    rm -f /tmp/zquestz-key.gpg
else
    if curl -fsSL --max-time 30 --retry 3 \
        https://zquestz.github.io/ppa/debian/KEY.gpg -o /tmp/zquestz-key.gpg 2>/dev/null; then
        $SUDO gpg --dearmor -o /usr/share/keyrings/zquestz-archive-keyring.gpg /tmp/zquestz-key.gpg
        rm -f /tmp/zquestz-key.gpg
    else
        warn "Failed to download plank GPG key"
    fi
fi

echo "deb [signed-by=/usr/share/keyrings/zquestz-archive-keyring.gpg] https://zquestz.github.io/ppa/debian ./" \
    | $SUDO tee /etc/apt/sources.list.d/zquestz.list >/dev/null

apt_run update
apt_run install -y plank-reloaded

log "=== Part 1 Complete ==="
echo ""
echo "============================================================================="
echo " System installation complete!"
echo "============================================================================="
echo ""
echo " Next steps:"
echo "  1. Reboot the system:"
echo "     sudo reboot"
echo ""
echo "  2. After reboot, login via RDP once"
echo ""
echo "  3. Run Part 2 script to configure XFCE:"
echo "     curl -fsSL https://github.com/hexbyte42-bot/cyber-claw/raw/main/install-xfce-xrdp-part2.sh | bash"
echo ""
echo "============================================================================="
