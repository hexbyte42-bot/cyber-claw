#!/bin/bash
set -euo pipefail

# WPS Office Missing Fonts Installer
# Based on: https://aur.archlinux.org/packages/ttf-wps-fonts
# Source: https://github.com/ferion11/ttf-wps-fonts
#
# Installs symbol fonts required by WPS Office:
# - Symbol
# - Wingdings
# - Wingdings 2
# - Wingdings 3
# - MT Extra

USE_PROXY="${USE_PROXY:-false}"
FONT_URL="https://raw.githubusercontent.com/ferion11/ttf-wps-fonts/main"

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }

# Setup proxy if needed
if [[ "$USE_PROXY" == "true" || "$USE_PROXY" == "1" ]]; then
    if [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
        err "USE_PROXY=true but http_proxy/https_proxy not set"
    fi
    export http_proxy="${http_proxy}"
    export https_proxy="${https_proxy}"
    export HTTP_PROXY="${http_proxy}"
    export HTTPS_PROXY="${https_proxy}"
    log "Proxy enabled: $http_proxy"
fi

log "Installing WPS Office missing fonts..."
log "Source: https://github.com/wachin/ttf-wps-fonts"

# Create temporary directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"

# Font files to download
declare -A FONTS=(
    ["symbold.ttf"]="Symbol"
    ["wingding.ttf"]="Wingdings"
    ["WINGDNG2.ttf"]="Wingdings 2"
    ["WINGDNG3.ttf"]="Wingdings 3"
    ["mtextra.ttf"]="MT Extra"
)

# Download function with proxy support
download_font() {
    local file="$1"
    local name="$2"
    local url="${FONT_URL}/${file}"
    
    info "Downloading ${name}..."
    
    if [[ -n "$http_proxy" ]]; then
        if curl --proxy "$http_proxy" -fsSL "$url" -o "$file" 2>/dev/null; then
            log "✓ ${name} downloaded"
            return 0
        fi
    else
        if curl -fsSL "$url" -o "$file" 2>/dev/null; then
            log "✓ ${name} downloaded"
            return 0
        fi
    fi
    
    warn "Failed to download ${name}"
    return 1
}

# Download all fonts
log "Downloading fonts from GitHub releases..."
for file in "${!FONTS[@]}"; do
    download_font "$file" "${FONTS[$file]}" || true
done

# Verify we have at least some fonts
FONT_COUNT=$(ls -1 *.ttf 2>/dev/null | wc -l)
if [[ "$FONT_COUNT" -eq 0 ]]; then
    err "Failed to download any fonts. Check your network/proxy settings."
fi

log "Downloaded $FONT_COUNT font(s)"

# Install fonts
log "Installing fonts to system..."

# Create fonts directory
FONTS_DIR="/usr/share/fonts/truetype/wps-fonts"
sudo mkdir -p "$FONTS_DIR"

# Copy fonts
for file in *.ttf; do
    if [[ -f "$file" ]]; then
        sudo cp "$file" "$FONTS_DIR/"
        info "  Installed: $file"
    fi
done

# Set permissions
log "Setting permissions..."
sudo chmod 644 "$FONTS_DIR"/*.ttf

# Update font cache
log "Updating font cache..."
sudo fc-cache -fv >/dev/null 2>&1

# Verify installation
log "Verifying installation..."
INSTALLED=0
for name in "${FONTS[@]}"; do
    if fc-list | grep -qi "$name"; then
        ((INSTALLED++)) || true
    fi
done

echo ""
log "Installation complete!"
echo ""
echo "Installed fonts: $INSTALLED"
fc-list | grep -E "(Symbol|Wingdings|MT Extra)" | head -10 || true
echo ""

if [[ "$INSTALLED" -gt 0 ]]; then
    log "✓ Fonts installed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Close WPS Office completely"
    echo "  2. Clear WPS cache: rm -rf ~/.wps-office"
    echo "  3. Restart WPS Office"
    echo ""
    echo "The missing font warnings should be gone."
else
    warn "No fonts were detected after installation."
    echo "You may need to manually restart your session or reboot."
fi
