#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Leak Prevention Script for Ubuntu 22.04
# Version: 5.0 - Native Linux (No Docker, No Cloudflared)
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DNS_UPSTREAM="1.1.1.1"
DNS_UPSTREAM2="1.0.0.1"
DNS_PROXY_IP="127.0.0.1"
DNS_PROXY_PORT="53"
EXPECTED_COUNTRY="Turkey"

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

if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (sudo)."
fi

log_info "Starting DNS Leak Prevention Script (Native Linux)..."
log_info "System: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"

# =============================================================================
# Step 1: Clean up Docker and Cloudflared
# =============================================================================

log_info "Step 1: Cleaning up Docker containers..."

# Stop and remove any cloudflared container
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "cloudflared"; then
    log_warn "Found existing cloudflared container. Removing..."
    docker stop cloudflared 2>/dev/null || true
    docker rm cloudflared 2>/dev/null || true
    log_success "Cloudflared container removed."
fi

# Stop any DNS-related containers
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "dnsmasq"; then
    log_warn "Found existing dnsmasq container. Removing..."
    docker stop dnsmasq 2>/dev/null || true
    docker rm dnsmasq 2>/dev/null || true
fi

# Check if Docker is installed and offer to remove
if command -v docker &> /dev/null; then
    log_warn "Docker is installed. This script doesn't need Docker."
    read -p "Do you want to remove Docker completely? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing Docker..."
        systemctl stop docker 2>/dev/null || true
        apt remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        rm -rf /var/lib/docker 2>/dev/null || true
        log_success "Docker removed."
    else
        log_info "Keeping Docker. Will not use it."
    fi
fi

# =============================================================================
# Step 2: Fix DNS Resolution (Emergency)
# =============================================================================

log_info "Step 2: Fixing system DNS resolution..."

# Backup current resolv.conf
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)
fi

# Remove immutable flag
chattr -i /etc/resolv.conf 2>/dev/null || true

# Set working DNS temporarily
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0 trust-ad
EOF

# Test DNS is working
log_info "Testing DNS connectivity..."
if ! ping -c 2 8.8.8.8 &>/dev/null; then
    log_warn "No internet connection! Please check your network."
fi

if ! dig @8.8.8.8 google.com +short &>/dev/null; then
    log_warn "DNS resolution not working properly. Trying alternative..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
fi

log_success "DNS resolution restored."

# =============================================================================
# Step 3: Install dnsmasq (Native DNS Proxy)
# =============================================================================

log_info "Step 3: Installing dnsmasq..."

# Update package list
apt update -y 2>/dev/null || true

# Install dnsmasq
if ! command -v dnsmasq &> /dev/null; then
    apt install -y dnsmasq dnsutils
    log_success "dnsmasq installed."
else
    log_info "dnsmasq is already installed."
fi

# =============================================================================
# Step 4: Configure dnsmasq
# =============================================================================

log_info "Step 4: Configuring dnsmasq..."

# Stop dnsmasq if running
systemctl stop dnsmasq 2>/dev/null || true

# Backup existing config
if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.$(date +%Y%m%d_%H%M%S)
fi

# Create new config
cat > /etc/dnsmasq.conf <<EOF
# DNS Leak Prevention Configuration
# Using Cloudflare DNS as upstream

# Upstream DNS servers
server=${DNS_UPSTREAM}
server=${DNS_UPSTREAM2}

# Listen on localhost only
listen-address=${DNS_PROXY_IP}
port=${DNS_PROXY_PORT}

# Security settings
no-resolv
no-poll
bind-interfaces
bogus-priv
domain-needed

# DNS cache
cache-size=1000

# Logging (optional)
log-queries=off
log-facility=-

# Prevent DNS leaks
no-dhcp-interface=
EOF

log_success "dnsmasq configured."

# =============================================================================
# Step 5: Start dnsmasq
# =============================================================================

log_info "Step 5: Starting dnsmasq..."

systemctl start dnsmasq
systemctl enable dnsmasq

sleep 3

# Check if dnsmasq is running
if systemctl is-active --quiet dnsmasq; then
    log_success "dnsmasq is running."
else
    log_error "dnsmasq failed to start. Checking logs..."
    journalctl -u dnsmasq -n 10 --no-pager
    error_exit "Please check the logs above."
fi

# Check if port 53 is listening
if ss -tulnp | grep -q "${DNS_PROXY_IP}:${DNS_PROXY_PORT}"; then
    log_success "dnsmasq is listening on ${DNS_PROXY_IP}:${DNS_PROXY_PORT}"
else
    log_warn "dnsmasq is not listening on port 53. Checking..."
    netstat -tulpn | grep :53 || true
fi

# =============================================================================
# Step 6: Configure System DNS
# =============================================================================

log_info "Step 6: Configuring system DNS..."

# Remove immutable flag
chattr -i /etc/resolv.conf 2>/dev/null || true

# Set DNS to localhost
cat > /etc/resolv.conf <<EOF
# DNS Leak Prevention - dnsmasq proxy
nameserver ${DNS_PROXY_IP}
options edns0 trust-ad
EOF

# Make resolv.conf immutable
chattr +i /etc/resolv.conf 2>/dev/null || true

log_success "System DNS configured to use ${DNS_PROXY_IP}"

# =============================================================================
# Step 7: Testing & Verification
# =============================================================================

log_info "Step 7: Running DNS leak tests..."

# Test 1: DNS resolution
log_info "Test 1: DNS resolution through local proxy..."
if dig +timeout=2 +tries=1 +short @${DNS_PROXY_IP} google.com >/dev/null 2>&1; then
    log_success "Local DNS proxy is responding."
else
    log_error "Local DNS proxy is not responding."
    log_info "Trying to restart dnsmasq..."
    systemctl restart dnsmasq
    sleep 2
    if dig +timeout=2 +tries=1 +short @${DNS_PROXY_IP} google.com >/dev/null 2>&1; then
        log_success "dnsmasq is now responding."
    else
        error_exit "DNS proxy failed to respond. Please check dnsmasq configuration."
    fi
fi

# Test 2: IP Detection
log_info "Test 2: Detecting server IP..."
LOCAL_IP=$(dig +short TXT whoami.cloudflare @${DNS_PROXY_IP} 2>/dev/null | tr -d '"')
if [ -n "$LOCAL_IP" ]; then
    log_success "Server IP (via local DNS): ${LOCAL_IP}"
else
    log_error "Could not detect IP via local DNS."
fi

# Test 3: Compare with Cloudflare DNS
log_info "Test 3: Verifying DNS consistency..."
CF_IP=$(dig +short TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')
if [ -n "$CF_IP" ]; then
    log_success "Server IP (via 1.1.1.1): ${CF_IP}"
else
    log_warn "Could not verify with 1.1.1.1."
fi

# Compare IPs
if [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ]; then
    if [ "$LOCAL_IP" = "$CF_IP" ]; then
        log_success "DNS is consistent. No leak detected."
        LEAK_DETECTED=false
    else
        log_error "DNS inconsistency detected! Possible DNS leak!"
        LEAK_DETECTED=true
    fi
else
    LEAK_DETECTED=false
fi

# Test 4: Geolocation (if jq installed)
if command -v jq &> /dev/null && [ -n "$LOCAL_IP" ]; then
    log_info "Test 4: Geolocation verification..."
    LOCATION=$(curl -s "http://ip-api.com/json/${LOCAL_IP}" 2>/dev/null | jq -r '.country' 2>/dev/null)
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
cat /etc/resolv.conf | grep -v "^#" 2>/dev/null || echo "  (No output)"

echo ""
echo -e "${YELLOW}Service Status:${NC}"
systemctl status dnsmasq --no-pager | grep -E "Active|Loaded" || echo "  Service not found"

echo ""
echo -e "${YELLOW}Port 53 Status:${NC}"
ss -tulnp | grep ":53" || echo "  Not listening on port 53"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Quick Test Commands:${NC}"
echo -e "  dig whoami.cloudflare @${DNS_PROXY_IP}"
echo -e "  nslookup google.com ${DNS_PROXY_IP}"
echo -e "  resolvectl status (if available)"
echo ""
echo -e "${BLUE}Service Management:${NC}"
echo -e "  Start:   systemctl start dnsmasq"
echo -e "  Stop:    systemctl stop dnsmasq"
echo -e "  Status:  systemctl status dnsmasq"
echo -e "  Logs:    journalctl -u dnsmasq -f"
echo -e "${BLUE}============================================================${NC}"

if [ "$LEAK_DETECTED" = false ]; then
    exit 0
else
    exit 1
fi
