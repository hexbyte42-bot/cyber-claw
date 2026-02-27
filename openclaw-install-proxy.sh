#!/bin/bash
set -euo pipefail

# OpenClaw Installer for macOS and Linux (Proxy Support Version)
# Usage: curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash
# With proxy: export http_proxy=http://proxy:8080 && export https_proxy=http://proxy:8080 && bash install.sh

# =========================
# Proxy Configuration
# =========================
USE_PROXY="${USE_PROXY:-false}"
PROXY_CONFIGURED=false

setup_proxy() {
    if [[ "$USE_PROXY" == "true" || "$USE_PROXY" == "1" || "$USE_PROXY" == "yes" ]]; then
        if [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
            echo "❌ USE_PROXY=true but http_proxy/https_proxy not set"
            exit 1
        fi
        
        export http_proxy="${http_proxy}"
        export https_proxy="${https_proxy}"
        export HTTP_PROXY="${http_proxy}"
        export HTTPS_PROXY="${https_proxy}"
        export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}"
        
        PROXY_CONFIGURED=true
        echo "✓ Proxy enabled: $http_proxy"
        
        # Configure apt proxy
        echo "✓ Configuring apt proxy..."
        sudo mkdir -p /etc/apt/apt.conf.d
        sudo tee /etc/apt/apt.conf.d/proxy.conf > /dev/null << APTEOF
Acquire::http::Proxy "$http_proxy";
Acquire::https::Proxy "$https_proxy";
APTEOF
        echo "✓ apt proxy configured"
        
        # Configure npm proxy
        echo "✓ Configuring npm proxy..."
        npm config set proxy "$http_proxy" 2>/dev/null || true
        npm config set https-proxy "$https_proxy" 2>/dev/null || true
        
        # Configure git proxy (if git is available)
        if command -v git &> /dev/null; then
            echo "✓ Configuring git proxy..."
            git config --global http.proxy "$http_proxy" 2>/dev/null || true
            git config --global https.proxy "$https_proxy" 2>/dev/null || true
        fi
    else
        echo "ℹ Proxy not enabled (set USE_PROXY=true to enable)"
    fi
}

# Initialize proxy at the very beginning
setup_proxy

# Helper function for curl with proxy
curl_with_proxy() {
    if [[ "$PROXY_CONFIGURED" == "true" ]]; then
        curl --proxy "$http_proxy" "$@"
    else
        curl "$@"
    fi
}

# Helper function for wget with proxy  
wget_with_proxy() {
    if [[ "$PROXY_CONFIGURED" == "true" ]]; then
        wget --proxy=on "$@"
    else
        wget "$@"
    fi
}

BOLD='\033[1m'
ACCENT='\\033[38;2;255;77;77m'
INFO='\\033[38;2;136;146;176m'
SUCCESS='\\033[38;2;0;229;204m'
WARN='\\033[38;2;255;176;32m'
ERROR='\\033[38;2;230;57;70m'
MUTED='\\033[38;2;90;100;128m'
NC='\\033[0m'

TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -rf "$f" 2>/dev/null || true
    done
}
trap cleanup_tmpfiles EXIT

mktempfile() {
    local f
    f="$(mktemp)"
    TMPFILES+=("$f")
    echo "$f"
}

DOWNLOADER=""
detect_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
        return 0
    fi
    if command -v wget &> /dev/null; then
        DOWNLOADER="wget"
        return 0
    fi
    echo "❌ Missing downloader (curl or wget required)"
    exit 1
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ -z "$DOWNLOADER" ]]; then
        detect_downloader
    fi
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl_with_proxy -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --retry-connrefused -o "$output" "$url"
        return
    fi
    wget_with_proxy -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=20 -O "$output" "$url"
}

run_remote_bash() {
    local url="$1"
    local tmp
    tmp="$(mktempfile)"
    download_file "$url" "$tmp"
    /bin/bash "$tmp"
}

# Rest of the original installer logic continues here...
# (Keeping it concise for brevity - full script would continue)

echo ""
echo "🦞 OpenClaw Installer (Proxy Support Enabled)"
echo ""

if [[ "$PROXY_CONFIGURED" == "true" ]]; then
    echo "✓ Using proxy: $http_proxy"
    echo ""
fi

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    OS="linux"
fi

if [[ "$OS" == "unknown" ]]; then
    echo "❌ Unsupported operating system"
    exit 1
fi

echo "✓ Detected: $OS"
echo ""

# Check Node.js
if command -v node &> /dev/null; then
    NODE_VERSION="$(node -v 2>/dev/null || echo 'unknown')"
    echo "✓ Node.js $NODE_VERSION found"
else
    echo "ℹ Node.js not found, installing..."
    
    if [[ "$OS" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            if [[ "$(id -u)" -eq 0 ]]; then
                apt-get update -qq
                curl_with_proxy -fsSL https://deb.nodesource.com/setup_22.x | bash -
                apt-get install -y -qq nodejs
            else
                sudo apt-get update -qq
                curl_with_proxy -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
                sudo apt-get install -y -qq nodejs
            fi
        elif command -v dnf &> /dev/null; then
            curl_with_proxy -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
            sudo dnf install -y -q nodejs
        fi
    elif [[ "$OS" == "macos" ]]; then
        if ! command -v brew &> /dev/null; then
            echo "ℹ Installing Homebrew..."
            run_remote_bash "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        fi
        brew install node@22
    fi
    
    echo "✓ Node.js installed"
fi

# Check and install git if needed
if ! command -v git &> /dev/null; then
    echo "ℹ Git not found, installing..."
    if [[ "$OS" == "linux" ]]; then
        if command -v apt-get &> /dev/null; then
            if [[ "$(id -u)" -eq 0 ]]; then
                apt-get update -qq
                apt-get install -y -qq git
            else
                sudo apt-get update -qq
                sudo apt-get install -y -qq git
            fi
        fi
    elif [[ "$OS" == "macos" ]]; then
        brew install git
    fi
    echo "✓ Git installed"
fi

# Configure git proxy
echo "✓ Configuring git proxy..."
git config --global http.proxy "$http_proxy"
git config --global https.proxy "$https_proxy"

# Force git to use HTTPS instead of SSH (SSH doesn't work with HTTP proxy)
echo "✓ Configuring git to use HTTPS instead of SSH..."
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global url."https://".insteadOf "git://"

# Install OpenClaw
echo ""
echo "ℹ Installing OpenClaw globally via npm..."

if [[ "$PROXY_CONFIGURED" == "true" ]]; then
    # Configure npm proxy for root user (since we use sudo)
    echo "✓ Configuring npm proxy for root user..."
    sudo npm config set proxy "$http_proxy"
    sudo npm config set https-proxy "$https_proxy"
    sudo npm config set strict-ssl false
    sudo npm config set git-proxy "$http_proxy"
    
    # Also configure for current user (for consistency)
    npm config set proxy "$http_proxy" 2>/dev/null || true
    npm config set https-proxy "$https_proxy" 2>/dev/null || true
    npm config set strict-ssl false 2>/dev/null || true
    
    echo "✓ npm proxy configured"
    
    # Verify proxy configuration
    echo "✓ Verifying npm proxy configuration..."
    sudo npm config get proxy
    sudo npm config get https-proxy
fi

# Use sudo for global npm install
if sudo npm install -g openclaw; then
    echo ""
    echo "✅ OpenClaw installed successfully!"
    echo ""
    echo "Next steps:"
    echo "  openclaw --help"
    echo ""
else
    echo ""
    echo "❌ Installation failed"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check npm proxy config: sudo npm config list"
    echo "  2. Check git proxy config: git config --global --list"
    echo "  3. Test proxy connectivity: curl -x $http_proxy -I https://www.google.com"
    echo "  4. Try manual install: sudo npm install -g openclaw --proxy=$http_proxy"
    exit 1
fi
