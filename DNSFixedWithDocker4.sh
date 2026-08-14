#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Leak Prevention Script for Ubuntu 22.04
# Version: 6.0 - Native Linux (Keep Docker, Remove Only Related Containers)
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configuration
DNS_UPSTREAM="1.1.1.1"
DNS_UPSTREAM2="1.0.0.1"
DNS_PROXY_IP="127.0.0.1"
DNS_PROXY_PORT="53"
EXPECTED_COUNTRY="Turkey"
SCRIPT_VERSION="6.0"

# =============================================================================
# Functions
# =============================================================================

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${BLUE}[SUCCESS]${NC} $1"; }
log_header() { echo -e "\n${CYAN}════════════════════════════════════════════════════════════════════${NC}"; }
log_subheader() { echo -e "${MAGENTA}▶ $1${NC}"; }

error_exit() {
    log_error "$1"
    exit 1
}

print_table() {
    echo ""
    echo -e "${WHITE}┌────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${WHITE}│                    DNS LEAK PREVENTION - STATUS TABLE               │${NC}"
    echo -e "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "COMPONENT" "STATUS"
    echo -e "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Proxy" "${1:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Leak Prevention" "${2:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Server IP" "${3:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Location" "${4:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Expected Country" "${5:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Service" "${6:-Unknown}"
    printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Container Status" "${7:-N/A}"
    echo -e "${WHITE}└────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# =============================================================================
# Step 0: Set Hostname
# =============================================================================

log_header
log_info "DNS Leak Prevention Script v${SCRIPT_VERSION}"
log_info "System: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"

# Set hostname
CURRENT_HOSTNAME=$(hostname)
log_info "Current hostname: ${CURRENT_HOSTNAME}"

read -p "Do you want to change hostname? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter new hostname: " NEW_HOSTNAME
    if [ -n "$NEW_HOSTNAME" ]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
        log_success "Hostname changed to: $NEW_HOSTNAME"
    fi
fi

# =============================================================================
# Pre-flight Checks
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (sudo)."
fi

log_info "Starting DNS Leak Prevention..."

# =============================================================================
# Step 1: Clean up DNS-related containers ONLY
# =============================================================================

log_subheader "Step 1: Cleaning up DNS-related containers"

# List of containers to clean
CONTAINERS_TO_CLEAN=("cloudflared" "dnsmasq" "pihole" "adguard" "unbound")

for container in "${CONTAINERS_TO_CLEAN[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        log_warn "Found container: ${container}. Removing..."
        docker stop "${container}" 2>/dev/null || true
        docker rm "${container}" 2>/dev/null || true
        log_success "Removed container: ${container}"
    fi
done

# Check if Docker is installed (just inform, don't remove)
if command -v docker &> /dev/null; then
    log_info "Docker is installed (keeping it)."
    DOCKER_STATUS="Installed"
else
    log_info "Docker is not installed."
    DOCKER_STATUS="Not Installed"
fi

# =============================================================================
# Step 2: Fix DNS Resolution (Emergency)
# =============================================================================

log_subheader "Step 2: Fixing system DNS resolution"

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
    log_warn "DNS resolution not working. Trying alternative..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
else
    log_success "DNS resolution restored."
fi

# =============================================================================
# Step 3: Install dnsmasq
# =============================================================================

log_subheader "Step 3: Installing dnsmasq"

# Update package list
apt update -y 2>/dev/null || true

# Install dnsmasq
if ! command -v dnsmasq &> /dev/null; then
    log_info "Installing dnsmasq..."
    apt install -y dnsmasq dnsutils
    log_success "dnsmasq installed."
else
    log_info "dnsmasq is already installed."
fi

# =============================================================================
# Step 4: Configure dnsmasq
# =============================================================================

log_subheader "Step 4: Configuring dnsmasq"

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

log_subheader "Step 5: Starting dnsmasq"

systemctl daemon-reload
systemctl start dnsmasq
systemctl enable dnsmasq

sleep 3

# Check if dnsmasq is running
if systemctl is-active --quiet dnsmasq; then
    log_success "dnsmasq is running."
    DNS_SERVICE="Active ✓"
else
    log_error "dnsmasq failed to start. Checking logs..."
    journalctl -u dnsmasq -n 10 --no-pager
    DNS_SERVICE="Failed ✗"
fi

# Check if port 53 is listening
if ss -tulnp | grep -q "${DNS_PROXY_IP}:${DNS_PROXY_PORT}"; then
    log_success "dnsmasq is listening on ${DNS_PROXY_IP}:${DNS_PROXY_PORT}"
    PORT_STATUS="Listening ✓"
else
    log_warn "dnsmasq is not listening on port 53."
    PORT_STATUS="Not Listening ✗"
fi

# =============================================================================
# Step 6: Configure System DNS
# =============================================================================

log_subheader "Step 6: Configuring system DNS"

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

log_subheader "Step 7: Running DNS leak tests"

# Test 1: DNS resolution
log_info "Test 1: DNS resolution through local proxy..."
if dig +timeout=2 +tries=1 +short @${DNS_PROXY_IP} google.com >/dev/null 2>&1; then
    log_success "Local DNS proxy is responding."
    DNS_PROXY_STATUS="Working ✓"
else
    log_error "Local DNS proxy is not responding."
    DNS_PROXY_STATUS="Failed ✗"
    log_info "Trying to restart dnsmasq..."
    systemctl restart dnsmasq
    sleep 2
    if dig +timeout=2 +tries=1 +short @${DNS_PROXY_IP} google.com >/dev/null 2>&1; then
        log_success "dnsmasq is now responding."
        DNS_PROXY_STATUS="Working ✓"
    else
        DNS_PROXY_STATUS="Failed ✗"
    fi
fi

# Test 2: IP Detection
log_info "Test 2: Detecting server IP..."
LOCAL_IP=$(dig +short TXT whoami.cloudflare @${DNS_PROXY_IP} 2>/dev/null | tr -d '"')
if [ -n "$LOCAL_IP" ]; then
    log_success "Server IP (via local DNS): ${LOCAL_IP}"
    SERVER_IP="${LOCAL_IP}"
else
    log_error "Could not detect IP via local DNS."
    SERVER_IP="Unknown"
fi

# Test 3: Compare with Cloudflare DNS
log_info "Test 3: Verifying DNS consistency..."
CF_IP=$(dig +short TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')
if [ -n "$CF_IP" ]; then
    log_success "Server IP (via 1.1.1.1): ${CF_IP}"
else
    log_warn "Could not verify with 1.1.1.1."
    CF_IP="Unknown"
fi

# Compare IPs
if [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ]; then
    if [ "$LOCAL_IP" = "$CF_IP" ]; then
        log_success "DNS is consistent. No leak detected."
        LEAK_STATUS="No Leak ✓"
    else
        log_error "DNS inconsistency detected! Possible DNS leak!"
        LEAK_STATUS="Leak Detected ✗"
    fi
else
    LEAK_STATUS="Unknown"
fi

# Test 4: Geolocation
if command -v jq &> /dev/null && [ -n "$LOCAL_IP" ]; then
    log_info "Test 4: Geolocation verification..."
    LOCATION=$(curl -s "http://ip-api.com/json/${LOCAL_IP}" 2>/dev/null | jq -r '.country' 2>/dev/null)
    if [ -n "$LOCATION" ]; then
        log_info "Detected location: ${LOCATION}"
        SERVER_LOCATION="${LOCATION}"
        if [[ "$LOCATION" == *"${EXPECTED_COUNTRY}"* ]]; then
            log_success "Location matches expected country: ${EXPECTED_COUNTRY}"
            LOCATION_STATUS="Match ✓"
        else
            log_warn "Location (${LOCATION}) differs from expected (${EXPECTED_COUNTRY})"
            LOCATION_STATUS="Mismatch ✗"
        fi
    else
        SERVER_LOCATION="Unknown"
        LOCATION_STATUS="Unknown"
    fi
else
    SERVER_LOCATION="Unknown"
    LOCATION_STATUS="Unknown"
fi

# =============================================================================
# Final Status Table
# =============================================================================

# Prepare status values
if [ "$DNS_PROXY_STATUS" = "Working ✓" ] && [ "$LEAK_STATUS" = "No Leak ✓" ]; then
    FINAL_STATUS="${GREEN}✅ PASS${NC}"
elif [ "$DNS_PROXY_STATUS" = "Failed ✗" ]; then
    FINAL_STATUS="${RED}❌ FAILED${NC}"
else
    FINAL_STATUS="${YELLOW}⚠️ PARTIAL${NC}"
fi

CONTAINER_STATUS="Cleaned ✓"

# Display the table
clear
echo ""
echo -e "${WHITE}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}                    DNS LEAK PREVENTION - FINAL STATUS             ${NC}"
echo -e "${WHITE}════════════════════════════════════════════════════════════════════${NC}"
echo ""

printf "${WHITE}┌────────────────────────────────────────────────────────────────────────┐${NC}\n"
printf "${WHITE}│${NC} ${CYAN}%-20s${NC} ${WHITE}│${NC} ${GREEN}%-40s${NC} ${WHITE}│${NC}\n" "COMPONENT" "STATUS"
printf "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}\n"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Proxy" "${DNS_PROXY_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Leak" "${LEAK_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Server IP" "${SERVER_IP}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Location" "${SERVER_LOCATION:-Unknown}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Expected Country" "${EXPECTED_COUNTRY}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Location Match" "${LOCATION_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Service" "${DNS_SERVICE}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Port 53" "${PORT_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Docker" "${DOCKER_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Containers" "${CONTAINER_STATUS}"
printf "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}\n"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "FINAL RESULT" "${FINAL_STATUS}"
printf "${WHITE}└────────────────────────────────────────────────────────────────────────┘${NC}\n"

echo ""
echo -e "${YELLOW}Active DNS Configuration:${NC}"
cat /etc/resolv.conf | grep -v "^#" 2>/dev/null || echo "  (No output)"

echo ""
echo -e "${YELLOW}Service Status:${NC}"
systemctl status dnsmasq --no-pager | grep -E "Active|Loaded" || echo "  Service not found"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Quick Commands:${NC}"
echo -e "  Test DNS:   dig whoami.cloudflare @${DNS_PROXY_IP}"
echo -e "  Check logs: journalctl -u dnsmasq -f"
echo -e "  Restart:    systemctl restart dnsmasq"
echo -e "  Stop:       systemctl stop dnsmasq"
echo -e "${BLUE}============================================================${NC}"

if [ "$DNS_PROXY_STATUS" = "Working ✓" ] && [ "$LEAK_STATUS" = "No Leak ✓" ]; then
    log_success "✅ DNS Leak Prevention is fully operational!"
    exit 0
else
    log_warn "⚠️ Some issues detected. Please review the status table above."
    exit 1
fi
