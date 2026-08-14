#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Leak Prevention Script for Ubuntu 22.04
# Version: 7.0 - FINAL STABLE (Fully Tested)
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
SCRIPT_VERSION="7.0"

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

# =============================================================================
# Step 0: Root Check & Hostname
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root (sudo)."
fi

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
        hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME"
        if ! grep -q "127.0.1.1.*$NEW_HOSTNAME" /etc/hosts; then
            echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
        fi
        log_success "Hostname changed to: $NEW_HOSTNAME"
    fi
fi

# =============================================================================
# Step 1: Stop systemd-resolved (Prevent port conflict)
# =============================================================================

log_subheader "Step 1: Stopping systemd-resolved"

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log_warn "systemd-resolved is running. Stopping to prevent port conflict..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    log_success "systemd-resolved stopped and disabled."
else
    log_info "systemd-resolved is not running."
fi

# =============================================================================
# Step 2: Clean up DNS-related containers
# =============================================================================

log_subheader "Step 2: Cleaning up DNS containers"

if command -v docker &> /dev/null; then
    DOCKER_STATUS="Installed ✓"
    for container in cloudflared dnsmasq pihole adguard unbound; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            log_warn "Removing container: ${container}"
            docker stop "${container}" 2>/dev/null || true
            docker rm "${container}" 2>/dev/null || true
            log_success "Removed: ${container}"
        fi
    done
else
    DOCKER_STATUS="Not Installed"
    log_info "Docker not found. Skipping container cleanup."
fi

# =============================================================================
# Step 3: Fix DNS Resolution (Emergency)
# =============================================================================

log_subheader "Step 3: Fixing system DNS resolution"

# Backup current resolv.conf
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)
    log_info "Backup created: /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)"
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
if dig @8.8.8.8 google.com +short &>/dev/null; then
    log_success "DNS resolution restored."
else
    log_warn "DNS resolution not working. Trying alternative..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    if dig @1.1.1.1 google.com +short &>/dev/null; then
        log_success "DNS resolution restored with 1.1.1.1"
    else
        log_warn "DNS still not working. Will continue anyway..."
    fi
fi

# =============================================================================
# Step 4: Install/Reinstall dnsmasq properly
# =============================================================================

log_subheader "Step 4: Installing dnsmasq"

# Remove any broken installation
apt remove -y dnsmasq dnsmasq-base 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

# Update and install
apt update -y 2>/dev/null || true
apt install -y dnsmasq dnsutils

if ! command -v dnsmasq &> /dev/null; then
    error_exit "Failed to install dnsmasq. Please check your package manager."
fi

log_success "dnsmasq installed: $(dnsmasq --version | head -1)"

# =============================================================================
# Step 5: Configure dnsmasq
# =============================================================================

log_subheader "Step 5: Configuring dnsmasq"

# Kill any running dnsmasq processes
pkill dnsmasq 2>/dev/null || true

# Backup existing config
if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.$(date +%Y%m%d_%H%M%S)
fi

# Create clean config
cat > /etc/dnsmasq.conf <<'EOF'
# DNS Leak Prevention - dnsmasq
# Upstream DNS (Cloudflare)
server=1.1.1.1
server=1.0.0.1

# Listen on localhost only
listen-address=127.0.0.1
port=53

# Security
no-resolv
no-poll
bind-interfaces
bogus-priv
domain-needed

# Cache
cache-size=1000

# No DHCP
no-dhcp-interface=

# Logging
log-queries=off
log-facility=-
EOF

log_success "dnsmasq configured."

# =============================================================================
# Step 6: Start dnsmasq (Multiple methods)
# =============================================================================

log_subheader "Step 6: Starting dnsmasq"

STARTED=false
DNS_SERVICE="Failed ✗"

# Method 1: Try systemd
log_info "Method 1: Trying systemd..."
if systemctl start dnsmasq 2>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
    systemctl enable dnsmasq 2>/dev/null || true
    log_success "dnsmasq started via systemd"
    STARTED=true
    DNS_SERVICE="Active (systemd) ✓"
fi

# Method 2: Try direct start with absolute path
if [ "$STARTED" = false ]; then
    log_info "Method 2: Trying direct start..."
    if /usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.conf 2>/dev/null; then
        log_success "dnsmasq started directly"
        STARTED=true
        DNS_SERVICE="Active (direct) ✓"
    fi
fi

# Method 3: Try with no-daemon flag (background)
if [ "$STARTED" = false ]; then
    log_info "Method 3: Trying with no-daemon flag..."
    if /usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon &>/dev/null & then
        sleep 2
        if pgrep dnsmasq > /dev/null; then
            log_success "dnsmasq started with no-daemon"
            STARTED=true
            DNS_SERVICE="Active (no-daemon) ✓"
        fi
    fi
fi

# Method 4: Try using dnsmasq from PATH
if [ "$STARTED" = false ]; then
    log_info "Method 4: Trying dnsmasq from PATH..."
    if dnsmasq --conf-file=/etc/dnsmasq.conf 2>/dev/null; then
        log_success "dnsmasq started from PATH"
        STARTED=true
        DNS_SERVICE="Active (PATH) ✓"
    fi
fi

sleep 2

# Verify dnsmasq is running
if ! pgrep dnsmasq > /dev/null; then
    log_error "All start methods failed!"
    log_info "Trying one last time with debug output..."
    dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon --log-queries &
    sleep 3
    if pgrep dnsmasq > /dev/null; then
        log_success "dnsmasq started with debug mode"
        STARTED=true
        DNS_SERVICE="Active (debug) ✓"
    fi
fi

if [ "$STARTED" = false ]; then
    error_exit "Failed to start dnsmasq. Check: /var/log/syslog"
fi

# =============================================================================
# Step 7: Check port 53
# =============================================================================

log_subheader "Step 7: Verifying port 53"

PORT_STATUS="Not Listening ✗"
if ss -tulnp | grep -q ":53"; then
    log_success "Port 53 is listening"
    PORT_STATUS="Listening ✓"
    ss -tulnp | grep :53
else
    log_warn "Port 53 is not listening. Checking process..."
    pgrep -a dnsmasq || true
fi

# =============================================================================
# Step 8: Configure System DNS
# =============================================================================

log_subheader "Step 8: Configuring system DNS"

# Remove immutable flag
chattr -i /etc/resolv.conf 2>/dev/null || true

# Set DNS to localhost
cat > /etc/resolv.conf <<EOF
# DNS Leak Prevention - dnsmasq proxy
nameserver 127.0.0.1
options edns0 trust-ad
EOF

# Make resolv.conf immutable
chattr +i /etc/resolv.conf 2>/dev/null || true

log_success "System DNS configured to use 127.0.0.1"

# =============================================================================
# Step 9: Testing & Verification
# =============================================================================

log_subheader "Step 9: Running DNS leak tests"

# Test 1: DNS resolution
log_info "Test 1: DNS resolution through local proxy..."
if dig +timeout=2 +tries=1 +short @127.0.0.1 google.com >/dev/null 2>&1; then
    log_success "Local DNS proxy is responding"
    DNS_PROXY_STATUS="Working ✓"
else
    log_error "Local DNS proxy is not responding"
    DNS_PROXY_STATUS="Failed ✗"
    log_info "Checking dnsmasq process..."
    ps aux | grep dnsmasq | grep -v grep || true
fi

# Test 2: IP Detection
log_info "Test 2: Detecting server IP..."
LOCAL_IP=$(dig +short TXT whoami.cloudflare @127.0.0.1 2>/dev/null | tr -d '"')
if [ -n "$LOCAL_IP" ]; then
    log_success "Server IP: ${LOCAL_IP}"
    SERVER_IP="${LOCAL_IP}"
else
    log_error "Could not detect IP via local DNS"
    SERVER_IP="Unknown"
fi

# Test 3: Compare with Cloudflare DNS
log_info "Test 3: Verifying DNS consistency..."
CF_IP=$(dig +short TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')
if [ -n "$CF_IP" ]; then
    log_success "Verified with 1.1.1.1: ${CF_IP}"
else
    log_warn "Could not verify with 1.1.1.1"
    CF_IP="Unknown"
fi

# Compare IPs
if [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ] && [ "$LOCAL_IP" = "$CF_IP" ]; then
    log_success "✅ No DNS leak detected"
    LEAK_STATUS="No Leak ✓"
elif [ -n "$LOCAL_IP" ] && [ -n "$CF_IP" ] && [ "$LOCAL_IP" != "$CF_IP" ]; then
    log_error "❌ DNS inconsistency detected!"
    LEAK_STATUS="Leak Detected ✗"
else
    LEAK_STATUS="Unknown"
fi

# Test 4: Geolocation (optional)
SERVER_LOCATION="Unknown"
LOCATION_STATUS="Unknown"
if command -v jq &> /dev/null && [ -n "$LOCAL_IP" ]; then
    log_info "Test 4: Geolocation verification..."
    LOCATION=$(curl -s --max-time 3 "http://ip-api.com/json/${LOCAL_IP}" 2>/dev/null | jq -r '.country' 2>/dev/null)
    if [ -n "$LOCATION" ]; then
        SERVER_LOCATION="${LOCATION}"
        if [[ "$LOCATION" == *"${EXPECTED_COUNTRY}"* ]]; then
            log_success "Location matches: ${EXPECTED_COUNTRY}"
            LOCATION_STATUS="Match ✓"
        else
            log_warn "Location: ${LOCATION} (Expected: ${EXPECTED_COUNTRY})"
            LOCATION_STATUS="Mismatch ✗"
        fi
    fi
fi

# =============================================================================
# Final Status Table
# =============================================================================

# Prepare final status
if [ "$DNS_PROXY_STATUS" = "Working ✓" ] && [ "$LEAK_STATUS" = "No Leak ✓" ]; then
    FINAL_STATUS="${GREEN}✅ PASS${NC}"
elif [ "$DNS_PROXY_STATUS" = "Failed ✗" ]; then
    FINAL_STATUS="${RED}❌ FAILED${NC}"
else
    FINAL_STATUS="${YELLOW}⚠️ PARTIAL${NC}"
fi

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
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Location" "${SERVER_LOCATION}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Expected" "${EXPECTED_COUNTRY}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Location Match" "${LOCATION_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "DNS Service" "${DNS_SERVICE}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Port 53" "${PORT_STATUS}"
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Docker" "${DOCKER_STATUS}"
printf "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}\n"
printf "${WHITE}│${NC} ${MAGENTA}%-20s${NC} ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "FINAL RESULT" "${FINAL_STATUS}"
printf "${WHITE}└────────────────────────────────────────────────────────────────────────┘${NC}\n"

echo ""
echo -e "${YELLOW}Active DNS Configuration:${NC}"
cat /etc/resolv.conf 2>/dev/null || echo "  (No output)"

echo ""
echo -e "${YELLOW}Service Status:${NC}"
if pgrep dnsmasq > /dev/null; then
    echo "  dnsmasq is running (PID: $(pgrep dnsmasq | tr '\n' ' '))"
else
    echo "  dnsmasq is NOT running"
fi

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Quick Commands:${NC}"
echo -e "  Test DNS:   dig whoami.cloudflare @127.0.0.1"
echo -e "  Check logs: journalctl -u dnsmasq -f  or  tail -f /var/log/syslog | grep dnsmasq"
echo -e "  Restart:    pkill dnsmasq && dnsmasq --conf-file=/etc/dnsmasq.conf"
echo -e "  Stop:       pkill dnsmasq"
echo -e "${BLUE}============================================================${NC}"

if [ "$DNS_PROXY_STATUS" = "Working ✓" ] && [ "$LEAK_STATUS" = "No Leak ✓" ]; then
    log_success "✅ DNS Leak Prevention is fully operational!"
    exit 0
else
    log_warn "⚠️ Some issues detected. Please review the status table above."
    exit 1
fi
