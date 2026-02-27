#!/bin/bash
set -uo pipefail

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
FONT_URL="https://raw.githubusercontent.com/ferion11/ttf-wps-fonts/master"

# Font files (actual names from repository)
declare -A FONTS=(
    ["symbol.ttf"]="Symbol"
    ["wingding.ttf"]="Wingdings"
    ["wingdng2.ttf"]="Wingdings 2"
    ["wingdng3.ttf"]="Wingdings 3"
    ["mtextra.ttf"]="MT Extra"
)

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
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
log "Source: https://github.com/ferion11/ttf-wps-fonts"

# Create temporary directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
cd "$TMPDIR"

# Download function with proxy support
download_font() {
    local file="$1"
    local name="$2"
    local url="${FONT_URL}/${file}"
    
    info "Downloading ${name}..."
    
    local curl_opts="-fsSL --retry 3 --retry-delay 2 --connect-timeout 10"
    
    if [[ -n "$http_proxy" ]]; then
        curl_opts="$curl_opts --proxy $http_proxy"
    fi
    
    if eval curl $curl_opts "$url" -o "$file" 2>/dev/null; then
        if [[ -f "$file" && -s "$file" ]]; then
            local size=$(ls -lh "$file" | awk '{print $5}')
            log "✓ ${name} downloaded (${size})"
            return 0
        fi
    fi
    
    warn "Failed to download ${name}"
    return 1
}

# Download all fonts
log "Downloading fonts..."
SUCCESS=0
FAILED=0

for file in "${!FONTS[@]}"; do
    if download_font "$file" "${FONTS[$file]}"; then
        ((SUCCESS++))
    else
        ((FAILED++))
    fi
done

log "Download complete: $SUCCESS successful, $FAILED failed"

# Verify we have at least some fonts
FONT_COUNT=$(ls -1 *.ttf 2>/dev/null | wc -l || echo "0")
if [[ "$FONT_COUNT" -eq 0 ]]; then
    err "Failed to download any fonts. Check your network/proxy settings."
fi

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
sudo fc-cache -fv 2>&1 | tail -3 || true

# Force reload font config
sudo fc-cache -frv >/dev/null 2>&1 || true

# Verify installation
log "Verifying installation..."
echo ""
echo "Checking installed font files..."
ls -lh "$FONTS_DIR"/*.ttf 2>/dev/null || echo "  No fonts found in $FONTS_DIR"
echo ""

INSTALLED=0
for name in "${FONTS[@]}"; do
    if fc-list | grep -qi "$name" 2>/dev/null; then
        ((INSTALLED++))
    else
        # Also check if file exists in fonts directory
        if ls "$FONTS_DIR"/*${name}* 2>/dev/null | head -1 | grep -q .; then
            ((INSTALLED++))
        fi
    fi
done

echo ""
log "Installation complete!"
echo ""
echo "Installed fonts: $INSTALLED / ${#FONTS[@]}"

if [[ "$INSTALLED" -gt 0 ]]; then
    log "✓ $INSTALLED / ${#FONTS[@]} fonts installed successfully!"
    echo ""
    echo "Installed font files:"
    ls -1 "$FONTS_DIR"/*.ttf 2>/dev/null | xargs -I {} basename {} | head -10 || true
    echo ""
    echo "Next steps:"
    echo "  1. Close WPS Office completely"
    echo "  2. Clear WPS cache: rm -rf ~/.wps-office"
    echo "  3. Restart WPS Office"
    echo ""
    echo "If fonts still not showing, try:"
    echo "  - Log out and log back in"
    echo "  - Or reboot: sudo reboot"
    echo ""
    echo "The missing font warnings should be gone."
else
    echo ""
    warn "Fonts installed but not detected by fc-list."
    echo ""
    echo "This is normal - fonts may take time to appear."
    echo ""
    echo "Required actions:"
    echo "  1. Log out and log back in (recommended)"
    echo "     OR"
    echo "  2. Reboot the system: sudo reboot"
    echo ""
    echo "After reboot, WPS should find the fonts automatically."
fi
