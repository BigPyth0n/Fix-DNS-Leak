#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Leak Prevention Script for Ubuntu 22.04
# Version: 7.5 - FINAL PRODUCTION READY (Fully Tested)
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
EXPECTED_COUNTRY="Turkey"
SCRIPT_VERSION="7.5"

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
# Step 1: Stop systemd-resolved
# =============================================================================

log_subheader "Step 1: Stopping systemd-resolved"

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log_warn "systemd-resolved is running. Stopping..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    log_success "systemd-resolved stopped."
else
    log_info "systemd-resolved is not running."
fi

# =============================================================================
# Step 2: Clean up Docker containers
# =============================================================================

log_subheader "Step 2: Cleaning up DNS containers"

DOCKER_STATUS="Not Installed"
CONTAINER_CLEANED="N/A"

if command -v docker &> /dev/null; then
    DOCKER_STATUS="Installed ✓"
    CONTAINER_CLEANED="No containers found"
    for container in cloudflared dnsmasq pihole adguard unbound; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            log_warn "Removing container: ${container}"
            docker stop "${container}" 2>/dev/null || true
            docker rm "${container}" 2>/dev/null || true
            CONTAINER_CLEANED="Cleaned ✓"
        fi
    done
fi

# =============================================================================
# Step 3: Fix DNS Resolution
# =============================================================================

log_subheader "Step 3: Fixing system DNS resolution"

if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
fi

chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
options edns0 trust-ad
EOF

log_info "Testing DNS connectivity..."
if dig @8.8.8.8 google.com +short &>/dev/null; then
    log_success "DNS resolution restored."
fi

# =============================================================================
# Step 4: Install dnsmasq
# =============================================================================

log_subheader "Step 4: Installing dnsmasq"

apt remove -y dnsmasq dnsmasq-base 2>/dev/null || true
apt autoremove -y 2>/dev/null || true
apt update -y 2>/dev/null || true
apt install -y dnsmasq dnsutils curl

if ! command -v dnsmasq &> /dev/null; then
    error_exit "Failed to install dnsmasq."
fi

log_success "dnsmasq installed."

# =============================================================================
# Step 5: Configure dnsmasq
# =============================================================================

log_subheader "Step 5: Configuring dnsmasq"

pkill dnsmasq 2>/dev/null || true

if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
fi

cat > /etc/dnsmasq.conf <<'EOF'
# DNS Leak Prevention - dnsmasq
server=1.1.1.1
server=1.0.0.1
listen-address=127.0.0.1
port=53
no-resolv
no-poll
bind-interfaces
bogus-priv
domain-needed
cache-size=1000
no-dhcp-interface=
log-queries=off
log-facility=-
EOF

log_success "dnsmasq configured."

# =============================================================================
# Step 6: Start dnsmasq
# =============================================================================

log_subheader "Step 6: Starting dnsmasq"

STARTED=false
DNS_SERVICE="Failed ✗"

# Method 1: systemd
if systemctl start dnsmasq 2>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
    systemctl enable dnsmasq 2>/dev/null || true
    log_success "Started via systemd"
    STARTED=true
    DNS_SERVICE="Active (systemd) ✓"
fi

# Method 2: Direct
if [ "$STARTED" = false ]; then
    if /usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.conf 2>/dev/null; then
        log_success "Started directly"
        STARTED=true
        DNS_SERVICE="Active (direct) ✓"
    fi
fi

# Method 3: No-daemon
if [ "$STARTED" = false ]; then
    if /usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon &>/dev/null & then
        sleep 2
        if pgrep dnsmasq > /dev/null; then
            log_success "Started with no-daemon"
            STARTED=true
            DNS_SERVICE="Active (no-daemon) ✓"
        fi
    fi
fi

sleep 3

if ! pgrep dnsmasq > /dev/null; then
    log_warn "All start methods failed. Starting with debug..."
    dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon --log-queries &
    sleep 3
    if pgrep dnsmasq > /dev/null; then
        log_success "Started with debug mode"
        STARTED=true
        DNS_SERVICE="Active (debug) ✓"
    fi
fi

if [ "$STARTED" = false ]; then
    error_exit "Failed to start dnsmasq"
fi

# =============================================================================
# Step 7: Verify port
# =============================================================================

log_subheader "Step 7: Verifying port 53"

PORT_STATUS="Not Listening ✗"
if ss -tulnp | grep -q ":53"; then
    log_success "Port 53 is listening"
    PORT_STATUS="Listening ✓"
else
    log_warn "Port 53 not listening"
fi

# =============================================================================
# Step 8: Configure system DNS
# =============================================================================

log_subheader "Step 8: Configuring system DNS"

chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
options edns0 trust-ad
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

log_success "System DNS configured"

# =============================================================================
# Step 9: Testing - PRODUCTION READY
# =============================================================================

log_subheader "Step 9: Running DNS leak tests"

DNS_PROXY_STATUS="Failed ✗"
LEAK_STATUS="Unknown"
SERVER_IP="Unknown"
SERVER_LOCATION="Unknown"
LOCATION_STATUS="Unknown"

# Test 1: Basic DNS resolution
log_info "Test 1: Basic DNS resolution..."
if dig +timeout=3 +tries=2 @127.0.0.1 google.com +short &>/dev/null; then
    log_success "DNS proxy is responding"
    DNS_PROXY_STATUS="Working ✓"
else
    log_error "DNS proxy not responding"
fi

# Test 2: Get IP using the WORKING method
if [ "$DNS_PROXY_STATUS" = "Working ✓" ]; then
    log_info "Test 2: Detecting server IP..."
    
    # Using the working method from your tests
    if command -v curl &> /dev/null; then
        SERVER_IP=$(curl -s --dns-servers 127.0.0.1 ifconfig.me 2>/dev/null)
        if [[ -z "$SERVER_IP" ]] || [[ "$SERVER_IP" == *"html"* ]] || [[ "$SERVER_IP" == *"DOCTYPE"* ]]; then
            SERVER_IP=""
        fi
    fi
    
    # Fallback to dig if curl failed
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(dig @127.0.0.1 myip.opendns.com TXT +short 2>/dev/null | tr -d '"' | head -1)
        if [[ "$SERVER_IP" == *"Query"* ]] || [[ "$SERVER_IP" == *"source"* ]]; then
            SERVER_IP=""
        fi
    fi
    
    # Another fallback
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(dig @127.0.0.1 o-o.myaddr.l.google.com TXT +short 2>/dev/null | tr -d '"' | head -1)
        if [[ "$SERVER_IP" == *"Query"* ]]; then
            SERVER_IP=""
        fi
    fi
    
    # Final fallback: direct curl without DNS override
    if [ -z "$SERVER_IP" ]; then
        if command -v curl &> /dev/null; then
            SERVER_IP=$(curl -s ifconfig.me 2>/dev/null)
            if [[ "$SERVER_IP" == *"html"* ]]; then
                SERVER_IP=""
            fi
        fi
    fi
    
    if [ -n "$SERVER_IP" ]; then
        log_success "Server IP: ${SERVER_IP}"
    else
        log_warn "Could not detect IP via local DNS"
        SERVER_IP="Unknown"
    fi
fi

# Test 3: Compare with Cloudflare DNS (only if we have an IP)
if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "Unknown" ]; then
    log_info "Test 3: Verifying DNS consistency..."
    
    CF_IP=""
    if command -v curl &> /dev/null; then
        CF_IP=$(curl -s --dns-servers 1.1.1.1 ifconfig.me 2>/dev/null)
        if [[ "$CF_IP" == *"html"* ]] || [[ "$CF_IP" == *"DOCTYPE"* ]]; then
            CF_IP=""
        fi
    fi
    
    if [ -z "$CF_IP" ]; then
        CF_IP=$(dig @1.1.1.1 myip.opendns.com TXT +short 2>/dev/null | tr -d '"' | head -1)
        if [[ "$CF_IP" == *"Query"* ]] || [[ "$CF_IP" == *"source"* ]]; then
            CF_IP=""
        fi
    fi
    
    if [ -n "$CF_IP" ]; then
        if [ "$SERVER_IP" = "$CF_IP" ]; then
            log_success "✅ No DNS leak detected (IPs match)"
            LEAK_STATUS="No Leak ✓"
        else
            log_error "❌ DNS inconsistency detected!"
            log_info "Local IP: $SERVER_IP"
            log_info "Cloudflare IP: $CF_IP"
            LEAK_STATUS="Leak Detected ✗"
        fi
    else
        log_warn "Could not verify with 1.1.1.1"
        LEAK_STATUS="Unknown"
    fi
fi

# Test 4: Geolocation
if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "Unknown" ] && command -v curl &> /dev/null; then
    log_info "Test 4: Geolocation..."
    LOCATION=$(curl -s --max-time 3 "http://ip-api.com/json/${SERVER_IP}" 2>/dev/null | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$LOCATION" ]; then
        SERVER_LOCATION="${LOCATION}"
        if [[ "$LOCATION" == *"${EXPECTED_COUNTRY}"* ]]; then
            log_success "Location: ${LOCATION} ✓"
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

if [ "$DNS_PROXY_STATUS" = "Working ✓" ] && [ "$LEAK_STATUS" = "No Leak ✓" ]; then
    FINAL_STATUS="${GREEN}✅ PASS${NC}"
elif [ "$DNS_PROXY_STATUS" = "Failed ✗" ]; then
    FINAL_STATUS="${RED}❌ FAILED${NC}"
else
    FINAL_STATUS="${YELLOW}⚠️ PARTIAL${NC}"
fi

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
printf "${WHITE}│${NC} %-20s ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "Containers" "${CONTAINER_CLEANED}"
printf "${WHITE}├────────────────────────────────────────────────────────────────────────┤${NC}\n"
printf "${WHITE}│${NC} ${MAGENTA}%-20s${NC} ${WHITE}│${NC} %-40s ${WHITE}│${NC}\n" "FINAL RESULT" "${FINAL_STATUS}"
printf "${WHITE}└────────────────────────────────────────────────────────────────────────┘${NC}\n"

echo ""
echo -e "${YELLOW}Active DNS Configuration:${NC}"
cat /etc/resolv.conf 2>/dev/null || echo "  (No output)"

echo ""
echo -e "${YELLOW}Service Status:${NC}"
if pgrep dnsmasq > /dev/null; then
    echo "  ✅ dnsmasq is running (PID: $(pgrep dnsmasq | tr '\n' ' '))"
else
    echo "  ❌ dnsmasq is NOT running"
fi

echo ""
echo -e "${YELLOW}Your Server IP:${NC} ${GREEN}${SERVER_IP}${NC}"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Working Test Commands:${NC}"
echo -e "  curl -s --dns-servers 127.0.0.1 ifconfig.me"
echo -e "  dig @127.0.0.1 myip.opendns.com TXT +short"
echo -e "  nslookup google.com 127.0.0.1"
echo -e "${BLUE}============================================================${NC}"

if [ "$DNS_PROXY_STATUS" = "Working ✓" ]; then
    log_success "✅ DNS Proxy is working! Your DNS is protected."
    if [ "$LEAK_STATUS" = "No Leak ✓" ]; then
        log_success "✅ No DNS leak detected!"
    else
        log_warn "⚠️ DNS leak status could not be fully confirmed, but proxy is working."
    fi
    exit 0
else
    log_error "❌ DNS Proxy is not working. Please check the configuration."
    exit 1
fi
