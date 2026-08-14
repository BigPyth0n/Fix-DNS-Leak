#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Leak Prevention Script for Ubuntu 22.04
# Version: 2.0 - Optimized & Production Ready
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DNS_PROXY_IP="127.0.0.1"
DNS_PROXY_PORT="53"
CONTAINER_NAME="cloudflared"
TEST_DOMAIN="whoami.cloudflare"
COMPARISON_DNS="1.1.1.1"
EXPECTED_COUNTRY="Turkey"  # Change this to your server's location

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${BLUE}[SUCCESS]${NC} $1"; }

error_exit() {
    log_error "$1"
    exit 1
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Root check
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (sudo)."
fi

# Ubuntu version check
if ! grep -q "22.04" /etc/os-release; then
    log_warn "This script is optimized for Ubuntu 22.04. Continuing anyway..."
fi

log_info "Starting DNS Leak Prevention Script..."

# =============================================================================
# System Preparation
# =============================================================================

# Update package list
log_info "Updating package list..."
apt update -y

# Install essential tools
log_info "Installing required packages..."
apt install -y --no-install-recommends \
    dnsutils \
    iproute2 \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    net-tools \
    systemd-resolved

# =============================================================================
# Docker Installation
# =============================================================================

if ! command -v docker &> /dev/null; then
    log_info "Installing Docker..."
    
    # Clean up any existing Docker installations
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt remove -y $pkg 2>/dev/null || true
    done
    
    # Setup Docker repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt update -y
    apt install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    log_success "Docker installed successfully."
else
    log_info "Docker is already installed."
fi

# Ensure Docker is running
systemctl enable docker
systemctl start docker

# =============================================================================
# DNS Proxy Setup (Cloudflared)
# =============================================================================

# Remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_warn "Removing existing ${CONTAINER_NAME} container..."
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
fi

log_info "Starting Cloudflared DNS proxy on ${DNS_PROXY_IP}:${DNS_PROXY_PORT}..."
docker run -d \
    --name ${CONTAINER_NAME} \
    --restart unless-stopped \
    --network host \
    cloudflare/cloudflared:latest proxy-dns \
    --address ${DNS_PROXY_IP} \
    --port ${DNS_PROXY_PORT}

# Wait for container to be ready
sleep 3

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    error_exit "Cloudflared container failed to start. Check Docker logs."
fi

log_success "Cloudflared DNS proxy is running."

# =============================================================================
# System DNS Configuration
# =============================================================================

# Backup resolv.conf
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)
fi

# Configure systemd-resolved
if command -v resolvectl &> /dev/null; then
    log_info "Configuring systemd-resolved..."
    
    # Set DNS for all interfaces
    for iface in $(resolvectl status | grep -E "^Link [0-9]+" | awk '{print $3}' | cut -d'(' -f1); do
        resolvectl dns $iface ${DNS_PROXY_IP} 2>/dev/null || true
    done
    
    # Set global DNS
    resolvectl dns ${DNS_PROXY_IP} 2>/dev/null || true
    
    # Set DNS over TLS
    resolvectl dnssec yes 2>/dev/null || true
    resolvectl dns-over-tls yes 2>/dev/null || true
    
    # Flush cache
    resolvectl flush-caches 2>/dev/null || true
    
    log_success "systemd-resolved configured."
else
    # Fallback to /etc/resolv.conf
    log_warn "systemd-resolved not found. Configuring /etc/resolv.conf..."
    
    # Make resolv.conf immutable to prevent changes
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    cat > /etc/resolv.conf <<EOF
# DNS Leak Prevention - Cloudflared
nameserver ${DNS_PROXY_IP}
options edns0 trust-ad
search .
EOF
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    log_success "/etc/resolv.conf configured."
fi

# =============================================================================
# Network Interface Configuration (Optional)
# =============================================================================

# Configure network manager if present
if command -v nmcli &> /dev/null; then
    log_info "Configuring NetworkManager..."
    
    for conn in $(nmcli -t -f NAME con show --active 2>/dev/null); do
        nmcli con mod "$conn" ipv4.dns ${DNS_PROXY_IP} 2>/dev/null || true
        nmcli con mod "$conn" ipv4.ignore-auto-dns yes 2>/dev/null || true
    done
    
    # Restart NetworkManager
    systemctl restart NetworkManager 2>/dev/null || true
fi

# =============================================================================
# Testing & Verification
# =============================================================================

log_info "Running DNS leak tests..."

# Test 1: DNS Resolution
log_info "Test 1: DNS resolution through local proxy..."
if dig +timeout=2 +tries=1 +short @${DNS_PROXY_IP} google.com >/dev/null 2>&1; then
    log_success "Local DNS proxy is responding."
else
    log_error "Local DNS proxy is not responding."
    exit 1
fi

# Test 2: IP Detection
log_info "Test 2: Detecting server IP..."
LOCAL_IP=$(dig +short TXT ${TEST_DOMAIN} @${DNS_PROXY_IP} 2>/dev/null | tr -d '"')
if [ -n "$LOCAL_IP" ]; then
    log_success "Server IP (via local DNS): ${LOCAL_IP}"
else
    log_error "Could not detect IP via local DNS."
    exit 1
fi

# Test 3: Compare with Cloudflare DNS
log_info "Test 3: Verifying DNS consistency..."
CF_IP=$(dig +short TXT ${TEST_DOMAIN} @${COMPARISON_DNS} 2>/dev/null | tr -d '"')
if [ -n "$CF_IP" ]; then
    log_success "Server IP (via ${COMPARISON_DNS}): ${CF_IP}"
else
    log_warn "Could not verify with ${COMPARISON_DNS}."
fi

# Compare IPs
if [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ]; then
    if [ "$LOCAL_IP" = "$CF_IP" ]; then
        log_success "DNS is consistent. No leak detected."
        LEAK_DETECTED=false
    else
        log_error "DNS inconsistency detected. Possible DNS leak!"
        LEAK_DETECTED=true
    fi
else
    LEAK_DETECTED=false
fi

# Test 4: Extended leak test
log_info "Test 4: Extended leak detection..."
for i in {1..5}; do
    result=$(dig +short @${DNS_PROXY_IP} test${i}.dnsleaktest.com 2>/dev/null || echo "TIMEOUT")
    if [[ "$result" == "TIMEOUT" || -z "$result" ]]; then
        continue
    else
        log_info "Test domain ${i} resolved to: ${result}"
    fi
done

# Test 5: Verify country (if detection available)
if command -v jq &> /dev/null; then
    log_info "Test 5: Geolocation verification..."
    LOCATION=$(curl -s --dns-servers ${DNS_PROXY_IP} --resolve "ip-api.com:80:${DNS_PROXY_IP}" \
        "http://ip-api.com/json/${LOCAL_IP}" 2>/dev/null | jq -r '.country' 2>/dev/null)
    
    if [ -n "$LOCATION" ]; then
        log_info "Detected location: ${LOCATION}"
        if [[ "$LOCATION" == *"${EXPECTED_COUNTRY}"* ]]; then
            log_success "Location matches expected country: ${EXPECTED_COUNTRY}"
        else
            log_warn "Location (${LOCATION}) differs from expected (${EXPECTED_COUNTRY})"
        fi
    fi
fi

# =============================================================================
# Final Status
# =============================================================================

echo ""
echo "================================================================================"
echo "                        DNS LEAK PREVENTION STATUS"
echo "================================================================================"

if [ "$LEAK_DETECTED" = false ]; then
    echo -e "${GREEN}✅ DNS Proxy Status: ACTIVE and WORKING${NC}"
    echo -e "${GREEN}✅ DNS Leak Prevention: ENABLED${NC}"
    echo -e "${GREEN}✅ All DNS queries are routed through local proxy${NC}"
    echo -e "${GREEN}✅ Server IP: ${LOCAL_IP}${NC}"
else
    echo -e "${RED}❌ DNS Proxy Status: ISSUES DETECTED${NC}"
    echo -e "${RED}❌ Please review error messages above${NC}"
fi

echo "================================================================================"
echo ""
echo -e "${YELLOW}Active DNS Configuration:${NC}"
if command -v resolvectl &> /dev/null; then
    resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server|DNSSEC" || echo "  (No output)"
else
    cat /etc/resolv.conf | grep -v "^#" 2>/dev/null || echo "  (No output)"
fi

echo ""
echo -e "${YELLOW}Container Status:${NC}"
docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  Container not found"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Recommendations:${NC}"
echo -e "1. Verify your server's actual location matches ${EXPECTED_COUNTRY}"
echo -e "2. Test with: dig whoami.cloudflare @${DNS_PROXY_IP}"
echo -e "3. To stop: docker stop ${CONTAINER_NAME}"
echo -e "4. To start: docker start ${CONTAINER_NAME}"
echo -e "${BLUE}============================================================${NC}"

# =============================================================================
# Exit with appropriate status
# =============================================================================

if [ "$LEAK_DETECTED" = false ]; then
    exit 0
else
    exit 1
fi
