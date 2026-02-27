#!/bin/bash
set -euo pipefail

# WPS Office Missing Fonts Installer
# Installs Wingdings and other symbol fonts for WPS Office on Linux

USE_PROXY="${USE_PROXY:-false}"

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }

# Setup proxy if needed
if [[ "$USE_PROXY" == "true" || "$USE_PROXY" == "1" ]]; then
    if [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
        err "USE_PROXY=true but proxy variables not set"
    fi
    export http_proxy="${http_proxy}"
    export https_proxy="${https_proxy}"
    export HTTP_PROXY="${http_proxy}"
    export HTTPS_PROXY="${https_proxy}"
    log "Proxy enabled: $http_proxy"
fi

log "Installing WPS Office missing fonts..."

# Create fonts directory
FONTS_DIR="/usr/share/fonts/truetype/wps-symbol-fonts"
sudo mkdir -p "$FONTS_DIR"

# Download and install fonts
# Using free alternatives from ttf-mscorefonts-installer and other sources

log "Installing Microsoft Core Fonts (includes some symbol fonts)..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq ttf-mscorefonts-installer fontconfig
elif command -v dnf &> /dev/null; then
    sudo dnf install -y -q mscore-fonts fontconfig
fi

# Download Wingdings alternatives
log "Downloading symbol fonts..."

# Download from GitHub mirror (ttf-wingdings)
WINGDINGS_URL="https://github.com/tommi77/wingdings-font/raw/master/wingding.ttf"
WINGDINGS2_URL="https://github.com/tommi77/wingdings-font/raw/master/wingdng2.ttf"
WINGDINGS3_URL="https://github.com/tommi77/wingdings-font/raw/master/wingdng3.ttf"

cd /tmp

# Download with proxy support
download_font() {
    local url="$1"
    local output="$2"
    if [[ -n "$http_proxy" ]]; then
        curl --proxy "$http_proxy" -fsSL "$url" -o "$output" 2>/dev/null || return 1
    else
        curl -fsSL "$url" -o "$output" 2>/dev/null || return 1
    fi
}

log "Downloading Wingdings..."
if download_font "$WINGDINGS_URL" "wingding.ttf"; then
    sudo mv wingding.ttf "$FONTS_DIR/Wingdings.ttf"
    echo "  ✓ Wingdings installed"
else
    warn "Failed to download Wingdings, using alternative..."
    # Try alternative source
    curl -fsSL "https://raw.githubusercontent.com/tommi77/wingdings-font/master/wingding.ttf" -o "wingding.ttf" 2>/dev/null && \
    sudo mv wingding.ttf "$FONTS_DIR/Wingdings.ttf" && \
    echo "  ✓ Wingdings installed (alternative source)" || \
    warn "Wingdings not available"
fi

log "Downloading Wingdings 2..."
if download_font "$WINGDINGS2_URL" "wingdng2.ttf"; then
    sudo mv wingdng2.ttf "$FONTS_DIR/Wingdings2.ttf"
    echo "  ✓ Wingdings 2 installed"
else
    warn "Failed to download Wingdings 2"
fi

log "Downloading Wingdings 3..."
if download_font "$WINGDINGS3_URL" "wingdng3.ttf" ; then
    sudo mv wingdng3.ttf "$FONTS_DIR/Wingdings3.ttf"
    echo "  ✓ Wingdings 3 installed"
else
    warn "Failed to download Wingdings 3"
fi

# Download Webdings (if available)
WEBDINGS_URL="https://github.com/tommi77/wingdings-font/raw/master/webdings.ttf"
log "Downloading Webdings..."
if download_font "$WEBDINGS_URL" "webdings.ttf"; then
    sudo mv webdings.ttf "$FONTS_DIR/Webdings.ttf"
    echo "  ✓ Webdings installed"
else
    warn "Failed to download Webdings"
fi

# Download MT Extra (if available)
MT_EXTRA_URL="https://github.com/tommi77/wingdings-font/raw/master/mtextra.ttf"
log "Downloading MT Extra..."
if download_font "$MT_EXTRA_URL" "mtextra.ttf"; then
    sudo mv mtextra.ttf "$FONTS_DIR/MT-Extra.ttf"
    echo "  ✓ MT Extra installed"
else
    warn "Failed to download MT Extra"
fi

# Update font cache
log "Updating font cache..."
sudo fc-cache -fv -y >/dev/null 2>&1 || sudo fc-cache -fv >/dev/null 2>&1

# Verify installation
log "Verifying font installation..."
if fc-list | grep -qi "wingdings"; then
    echo "  ✓ Wingdings fonts installed successfully"
else
    warn "Wingdings fonts may not be properly installed"
fi

# Clean up
cd - >/dev/null
rm -f /tmp/wingding.ttf /tmp/wingdng2.ttf /tmp/wingdng3.ttf /tmp/webdings.ttf /tmp/mtextra.ttf 2>/dev/null || true

log "Font installation complete!"
echo ""
echo "Note: If WPS still shows warnings, try:"
echo "  1. Restart WPS Office completely"
echo "  2. Clear WPS cache: rm -rf ~/.wps-office"
echo "  3. Reboot the system"
echo ""
echo "Installed fonts:"
echo "  - Wingdings"
echo "  - Wingdings 2"
echo "  - Wingdings 3"
echo "  - Webdings (if available)"
echo "  - MT Extra (if available)"
