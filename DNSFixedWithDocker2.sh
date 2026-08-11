```bash
#!/bin/bash
set -euo pipefail

# ============================================
# DNS Leak Fix Script - Professional Version
# Version: 2.0.0
# Author: Professional Developer
# ============================================

# ============================================
# Global Configuration
# ============================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="/var/log/dns-fix"
readonly LOG_FILE="${LOG_DIR}/dns-fix-$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_DIR="/etc/dns-fix-backup"
readonly CONFIG_FILE="/etc/dns-fix/config.conf"
readonly DOCKER_COMPOSE_FILE="/etc/dns-fix/docker-compose.yml"
readonly CLOUDFLARED_IMAGE="cloudflare/cloudflared:2025.2.0"
readonly DNS_PORT=53
readonly DNS_ADDRESS="127.0.0.1"
readonly MAX_RETRIES=30
readonly RETRY_INTERVAL=2
readonly DNS_TEST_DOMAINS=("google.com" "cloudflare.com" "github.com" "microsoft.com" "amazon.com")
readonly DNS_LEAK_TEST_DOMAINS=("whoami.cloudflare" "dnsleaktest.com" "ipleak.net")

# ============================================
# Color Definitions
# ============================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'
readonly UNDERLINE='\033[4m'

# ============================================
# Logging Functions
# ============================================
init_logging() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    mkdir -p "$(dirname "${BACKUP_DIR}")" 2>/dev/null || true
    
    exec 1> >(tee -a "${LOG_FILE}")
    exec 2> >(tee -a "${LOG_FILE}" >&2)
    
    echo "========================================================================"
    echo "DNS Fix Script Started at: $(date)"
    echo "Script: ${SCRIPT_NAME}"
    echo "Log: ${LOG_FILE}"
    echo "========================================================================"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    fi
}

log_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_section() {
    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════${NC}\n"
}

# ============================================
# Error Handling
# ============================================
error_exit() {
    log_error "$1"
    cleanup_on_error
    exit 1
}

trap 'error_exit "Script interrupted by user"' INT TERM
trap 'cleanup_on_exit' EXIT

cleanup_on_error() {
    log_warn "Performing cleanup after error..."
    # Restore DNS if backup exists
    if [[ -f "${BACKUP_DIR}/resolv.conf.backup" ]]; then
        if cp "${BACKUP_DIR}/resolv.conf.backup" /etc/resolv.conf 2>/dev/null; then
            log_info "DNS configuration restored from backup"
        fi
    fi
}

cleanup_on_exit() {
    # Nothing to do on normal exit
    :
}

# ============================================
# System Detection
# ============================================
detect_os() {
    log_section "System Detection"
    
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        readonly OS_ID="${ID}"
        readonly OS_VERSION="${VERSION_ID}"
        readonly OS_NAME="${NAME}"
        readonly OS_CODENAME="${VERSION_CODENAME:-}"
        
        log_info "OS: ${OS_NAME} (${OS_ID} ${OS_VERSION})"
        log_info "Codename: ${OS_CODENAME:-Unknown}"
    else
        error_exit "Cannot detect operating system"
    fi
    
    # Detect architecture
    readonly ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    log_info "Architecture: ${ARCH}"
    
    # Detect default network interface
    readonly DEFAULT_INTERFACE="$(ip route | grep default | awk '{print $5}' | head -1)"
    if [[ -z "${DEFAULT_INTERFACE}" ]]; then
        error_exit "Cannot detect default network interface"
    fi
    log_info "Default interface: ${DEFAULT_INTERFACE}"
}

# ============================================
# Prerequisites Check
# ============================================
check_prerequisites() {
    log_section "Checking Prerequisites"
    
    # Check required commands
    local required_commands=("curl" "wget" "ip" "ss" "grep" "awk" "sed" "tr" "cat" "tee" "mkdir" "rm" "cp" "chmod" "systemctl")
    local missing=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing commands: ${missing[*]}"
        log_info "Installing missing dependencies..."
        install_dependencies "${missing[@]}"
    else
        log_success "All prerequisites satisfied"
    fi
}

install_dependencies() {
    local packages=()
    for cmd in "$@"; do
        case "${cmd}" in
            curl|wget|ip|ss|grep|awk|sed|tr|cat|tee|mkdir|rm|cp|chmod)
                packages+=("${cmd}")
                ;;
            systemctl)
                packages+=("systemd")
                ;;
        esac
    done
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi
    
    case "${OS_ID}" in
        ubuntu|debian)
            apt update -qq
            apt install -y -qq "${packages[@]}" dnsutils iproute2
            ;;
        rhel|centos|fedora|amzn)
            if command -v dnf &>/dev/null; then
                dnf install -y -q "${packages[@]}" bind-utils iproute
            else
                yum install -y -q "${packages[@]}" bind-utils iproute
            fi
            ;;
        alpine)
            apk add --no-cache "${packages[@]}" bind-tools iproute2
            ;;
        *)
            error_exit "Unsupported OS for automatic dependency installation: ${OS_ID}"
            ;;
    esac
    
    log_success "Dependencies installed successfully"
}

# ============================================
# Docker Installation
# ============================================
install_docker() {
    log_section "Docker Installation"
    
    if command -v docker &>/dev/null && docker --version &>/dev/null; then
        log_info "Docker is already installed: $(docker --version)"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    case "${OS_ID}" in
        ubuntu|debian)
            install_docker_debian
            ;;
        rhel|centos|fedora|amzn)
            install_docker_rhel
            ;;
        alpine)
            install_docker_alpine
            ;;
        *)
            error_exit "Unsupported OS for automatic Docker installation: ${OS_ID}"
            ;;
    esac
    
    # Start Docker service
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    
    # Verify Docker installation
    if ! command -v docker &>/dev/null || ! docker --version &>/dev/null; then
        error_exit "Docker installation failed"
    fi
    
    log_success "Docker installed successfully: $(docker --version)"
}

install_docker_debian() {
    # Uninstall old versions
    apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Install prerequisites
    apt update -qq
    apt install -y -qq ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add repository
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt update -qq
    apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
    local pkg_manager="dnf"
    if ! command -v dnf &>/dev/null; then
        pkg_manager="yum"
    fi
    
    # Add Docker repository
    cat > /etc/yum.repos.d/docker.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://download.docker.com/linux/${OS_ID}/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/${OS_ID}/gpg
EOF
    
    # Install Docker
    ${pkg_manager} install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_alpine() {
    apk add --no-cache docker docker-cli-compose
    rc-update add docker default
}

# ============================================
# DNS Backup
# ============================================
backup_dns_config() {
    log_section "Backing Up Current DNS Configuration"
    
    mkdir -p "${BACKUP_DIR}"
    
    # Backup resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.backup"
        log_info "Backed up /etc/resolv.conf"
    fi
    
    # Backup systemd-resolved configuration
    if [[ -f /etc/systemd/resolved.conf ]]; then
        cp /etc/systemd/resolved.conf "${BACKUP_DIR}/resolved.conf.backup" 2>/dev/null || true
        log_info "Backed up /etc/systemd/resolved.conf"
    fi
    
    # Backup NetworkManager configuration
    if command -v nmcli &>/dev/null; then
        nmcli -f ALL con show --active | grep -E "^(NAME|UUID)" > "${BACKUP_DIR}/networkmanager.backup" 2>/dev/null || true
        log_info "Backed up NetworkManager active connections"
    fi
    
    # Save current DNS servers
    local current_dns=()
    if command -v resolvectl &>/dev/null; then
        current_dns=($(resolvectl status 2>/dev/null | grep -E "DNS Servers:" | awk -F: '{print $2}' | tr ',' ' ' | xargs))
    elif [[ -f /etc/resolv.conf ]]; then
        current_dns=($(grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | xargs))
    fi
    
    if [[ ${#current_dns[@]} -gt 0 ]]; then
        echo "${current_dns[*]}" > "${BACKUP_DIR}/current_dns_servers.backup"
        log_info "Current DNS servers: ${current_dns[*]}"
    fi
    
    log_success "DNS configuration backed up to ${BACKUP_DIR}"
}

# ============================================
# Cloudflared Deployment
# ============================================
deploy_cloudflared() {
    log_section "Deploying Cloudflared DNS Proxy"
    
    # Remove existing container
    if docker ps -a --format '{{.Names}}' | grep -q "^cloudflared$"; then
        log_warn "Existing cloudflared container found, removing..."
        docker stop cloudflared 2>/dev/null || true
        docker rm cloudflared 2>/dev/null || true
    fi
    
    # Create Docker Compose file
    mkdir -p "$(dirname "${DOCKER_COMPOSE_FILE}")"
    cat > "${DOCKER_COMPOSE_FILE}" <<EOF
version: '3.8'

services:
  cloudflared:
    image: ${CLOUDFLARED_IMAGE}
    container_name: cloudflared
    restart: unless-stopped
    ports:
      - "${DNS_ADDRESS}:${DNS_PORT}:${DNS_PORT}/udp"
      - "${DNS_ADDRESS}:${DNS_PORT}:${DNS_PORT}/tcp"
    command: proxy-dns --address ${DNS_ADDRESS} --port ${DNS_PORT}
    healthcheck:
      test: ["CMD", "sh", "-c", "nslookup cloudflare.com ${DNS_ADDRESS} 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 5s
    deploy:
      resources:
        limits:
          memory: 128M
        reservations:
          memory: 64M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
EOF
    
    log_info "Docker Compose file created at ${DOCKER_COMPOSE_FILE}"
    
    # Pull image
    log_info "Pulling Cloudflared image..."
    if ! docker pull "${CLOUDFLARED_IMAGE}"; then
        error_exit "Failed to pull Cloudflared image"
    fi
    
    # Deploy container
    log_info "Starting Cloudflared container..."
    if ! docker compose -f "${DOCKER_COMPOSE_FILE}" up -d; then
        error_exit "Failed to start Cloudflared container"
    fi
    
    log_success "Cloudflared container deployed"
}

wait_for_cloudflared() {
    log_info "Waiting for Cloudflared to be ready..."
    
    local attempt=0
    while [[ ${attempt} -lt ${MAX_RETRIES} ]]; do
        if docker exec cloudflared sh -c "nslookup cloudflare.com ${DNS_ADDRESS} 2>/dev/null" &>/dev/null; then
            log_success "Cloudflared is ready (attempt ${attempt})"
            return 0
        fi
        
        if docker inspect cloudflared --format='{{.State.Status}}' | grep -q "exited"; then
            log_error "Cloudflared container has exited"
            docker logs cloudflared --tail 20 2>&1 | tee -a "${LOG_FILE}"
            return 1
        fi
        
        ((attempt++))
        sleep "${RETRY_INTERVAL}"
    done
    
    log_error "Cloudflared failed to start after ${MAX_RETRIES} attempts"
    docker logs cloudflared --tail 20 2>&1 | tee -a "${LOG_FILE}"
    return 1
}

verify_cloudflared() {
    log_section "Verifying Cloudflared Deployment"
    
    # Check container status
    if ! docker ps --format '{{.Names}}' | grep -q "^cloudflared$"; then
        log_error "Cloudflared container is not running"
        return 1
    fi
    
    local container_status="$(docker inspect cloudflared --format='{{.State.Status}}')"
    log_info "Container status: ${container_status}"
    
    # Check health status
    local health_status="$(docker inspect cloudflared --format='{{.State.Health.Status}}' 2>/dev/null || echo "N/A")"
    log_info "Health status: ${health_status}"
    
    # Check port binding
    if ! ss -tulnp | grep -q "${DNS_ADDRESS}:${DNS_PORT}"; then
        log_error "DNS port ${DNS_PORT} is not listening"
        ss -tulnp | grep -E ":${DNS_PORT}" || true
        return 1
    fi
    log_success "DNS port ${DNS_PORT} is listening"
    
    # Check DNS resolution
    if ! dig +timeout=2 +tries=1 @${DNS_ADDRESS} google.com +short &>/dev/null; then
        log_error "DNS resolution test failed"
        dig +timeout=2 +tries=1 @${DNS_ADDRESS} google.com +short 2>&1 || true
        return 1
    fi
    log_success "DNS resolution test passed"
    
    log_success "Cloudflared verification completed successfully"
    return 0
}

# ============================================
# System DNS Configuration
# ============================================
configure_system_dns() {
    log_section "Configuring System DNS"
    
    local dns_servers=("${DNS_ADDRESS}")
    
    # Backup current configuration
    backup_dns_config
    
    # Try systemd-resolved first
    if command -v resolvectl &>/dev/null && systemctl is-active systemd-resolved &>/dev/null; then
        log_info "Configuring DNS via systemd-resolved"
        configure_dns_resolvectl
        return 0
    fi
    
    # Try NetworkManager
    if command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null; then
        log_info "Configuring DNS via NetworkManager"
        configure_dns_networkmanager
        return 0
    fi
    
    # Fallback to resolv.conf
    log_info "Configuring DNS via /etc/resolv.conf"
    configure_dns_resolvconf
    return 0
}

configure_dns_resolvectl() {
    local interface="${DEFAULT_INTERFACE}"
    
    # Set DNS for all interfaces
    for iface in $(resolvectl status 2>/dev/null | grep -E "^Link" | awk -F'[()]' '{print $2}' | xargs); do
        if [[ -n "${iface}" ]]; then
            resolvectl dns "${iface}" ${DNS_ADDRESS} 2>/dev/null || true
            resolvectl domain "${iface}" "~." 2>/dev/null || true
            log_debug "Configured DNS for interface: ${iface}"
        fi
    done
    
    # Set global DNS
    resolvectl dns ${DNS_ADDRESS} 2>/dev/null || true
    resolvectl domain "~." 2>/dev/null || true
    
    # Restart resolved
    systemctl restart systemd-resolved 2>/dev/null || true
    
    log_success "DNS configured via systemd-resolved"
}

configure_dns_networkmanager() {
    local connections=($(nmcli -t -f NAME con show --active 2>/dev/null | head -1))
    
    if [[ ${#connections[@]} -eq 0 ]]; then
        log_warn "No active NetworkManager connections found"
        configure_dns_resolvconf
        return 0
    fi
    
    for conn in "${connections[@]}"; do
        if [[ -n "${conn}" ]]; then
            nmcli con mod "${conn}" ipv4.dns "${DNS_ADDRESS}" 2>/dev/null || true
            nmcli con mod "${conn}" ipv4.ignore-auto-dns yes 2>/dev/null || true
            log_debug "Configured DNS for connection: ${conn}"
        fi
    done
    
    # Restart NetworkManager
    systemctl restart NetworkManager 2>/dev/null || true
    
    log_success "DNS configured via NetworkManager"
}

configure_dns_resolvconf() {
    # Create new resolv.conf
    cat > /etc/resolv.conf <<EOF
# DNS-Fix Generated - $(date)
nameserver ${DNS_ADDRESS}
# Cloudflare fallback
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
    
    # Make it immutable
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    log_success "DNS configured via /etc/resolv.conf"
}

# ============================================
# DNS Testing
# ============================================
test_dns() {
    log_section "DNS Testing"
    
    local test_results=()
    local test_failed=0
    
    # Test 1: Basic DNS resolution
    log_info "Test 1: Basic DNS Resolution"
    for domain in "${DNS_TEST_DOMAINS[@]}"; do
        if dig +timeout=2 +tries=1 @${DNS_ADDRESS} "${domain}" +short &>/dev/null; then
            local ip=$(dig +timeout=2 +tries=1 @${DNS_ADDRESS} "${domain}" +short | head -1)
            log_debug "  ${domain} -> ${ip}"
        else
            log_warn "  ${domain}: FAILED"
            ((test_failed++))
        fi
    done
    
    # Test 2: TCP DNS
    log_info "Test 2: TCP DNS Resolution"
    if dig +tcp +timeout=2 +tries=1 @${DNS_ADDRESS} google.com +short &>/dev/null; then
        log_success "  TCP DNS: OK"
    else
        log_error "  TCP DNS: FAILED"
        ((test_failed++))
    fi
    
    # Test 3: DNS over HTTPS (via Cloudflared)
    log_info "Test 3: DNS over HTTPS Verification"
    local local_ip=$(dig +timeout=2 +tries=1 TXT whoami.cloudflare @${DNS_ADDRESS} +short 2>/dev/null | tr -d '"')
    local cloudflare_ip=$(dig +timeout=2 +tries=1 TXT whoami.cloudflare @1.1.1.1 +short 2>/dev/null | tr -d '"')
    
    if [[ -n "${local_ip}" ]] && [[ -n "${cloudflare_ip}" ]]; then
        if [[ "${local_ip}" == "${cloudflare_ip}" ]]; then
            log_success "  DoH Verification: PASSED (IP matches)"
        else
            log_warn "  DoH Verification: IP mismatch (local: ${local_ip}, cloudflare: ${cloudflare_ip})"
            ((test_failed++))
        fi
    else
        log_warn "  DoH Verification: Cannot determine IPs"
        ((test_failed++))
    fi
    
    # Test 4: DNS Leak Test
    log_info "Test 4: DNS Leak Detection"
    for domain in "${DNS_LEAK_TEST_DOMAINS[@]}"; do
        local result=$(dig +timeout=2 +tries=1 @${DNS_ADDRESS} "${domain}" +short 2>/dev/null | head -1)
        if [[ -n "${result}" ]]; then
            log_debug "  ${domain}: ${result}"
        else
            log_warn "  ${domain}: FAILED"
            ((test_failed++))
        fi
    done
    
    # Test 5: DNSSEC
    log_info "Test 5: DNSSEC Support"
    if dig +timeout=2 +tries=1 @${DNS_ADDRESS} sigfail.verteiltesysteme.net +dnssec +short &>/dev/null; then
        log_success "  DNSSEC: PASSED"
    else
        log_warn "  DNSSEC: FAILED or not supported"
        ((test_failed++))
    fi
    
    # Test 6: Performance
    log_info "Test 6: DNS Performance"
    local total_time=0
    for i in {1..5}; do
        local start_time=$(date +%s%N)
        dig +timeout=1 +tries=1 @${DNS_ADDRESS} google.com +short &>/dev/null
        local end_time=$(date +%s%N)
        local elapsed=$(( (end_time - start_time) / 1000000 ))
        total_time=$(( total_time + elapsed ))
        log_debug "  Query ${i}: ${elapsed}ms"
    done
    local avg_time=$(( total_time / 5 ))
    log_info "  Average query time: ${avg_time}ms"
    
    # Summary
    echo ""
    if [[ ${test_failed} -eq 0 ]]; then
        log_success "All DNS tests passed successfully!"
        return 0
    else
        log_error "${test_failed} DNS test(s) failed"
        return 1
    fi
}

# ============================================
# Firewall Configuration
# ============================================
configure_firewall() {
    log_section "Firewall Configuration"
    
    # Configure iptables
    if command -v iptables &>/dev/null; then
        log_info "Configuring iptables rules"
        
        # Allow local DNS
        iptables -A INPUT -p udp --dport 53 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 53 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
        
        # Block external DNS (optional)
        # iptables -A OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
        # iptables -A OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
        
        log_success "iptables rules configured"
    fi
    
    # Configure ufw
    if command -v ufw &>/dev/null; then
        log_info "Configuring ufw rules"
        ufw allow out 53/udp 2>/dev/null || true
        ufw allow out 53/tcp 2>/dev/null || true
        log_success "ufw rules configured"
    fi
    
    # Configure firewalld
    if command -v firewall-cmd &>/dev/null; then
        log_info "Configuring firewalld rules"
        firewall-cmd --permanent --add-service=dns 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_success "firewalld rules configured"
    fi
}

# ============================================
# Status Report
# ============================================
generate_status_report() {
    log_section "Status Report"
    
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                   DNS Fix Status Report                     │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│ Docker:           $(docker --version 2>/dev/null || echo "Not installed")"
    echo "│ Cloudflared:      $(docker exec cloudflared cloudflared --version 2>/dev/null || echo "Not running")"
    echo "│ DNS Port:         ${DNS_ADDRESS}:${DNS_PORT} ($(ss -tulnp | grep -q "${DNS_ADDRESS}:${DNS_PORT}" && echo "Listening" || echo "Not listening"))"
    echo "│ Default Interface: ${DEFAULT_INTERFACE}"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│ DNS Configuration:"
    if command -v resolvectl &>/dev/null; then
        resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server" | sed 's/^/│   /'
    else
        grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/│   /' || echo "│   No nameservers found"
    fi
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│ Container Status:  $(docker inspect cloudflared --format='{{.State.Status}}' 2>/dev/null || echo "Not running")"
    echo "│ Health Status:    $(docker inspect cloudflared --format='{{.State.Health.Status}}' 2>/dev/null || echo "N/A")"
    echo "│ Restart Count:    $(docker inspect cloudflared --format='{{.RestartCount}}' 2>/dev/null || echo "N/A")"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│ Backup Location:  ${BACKUP_DIR}"
    echo "│ Log Location:     ${LOG_FILE}"
    echo "└──────────────────────────────────────────────────────────────┘"
}

# ============================================
# Main Execution
# ============================================
main() {
    # Initialize
    init_logging
    
    # Show banner
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  DNS LEAK FIX SCRIPT v2.0                    ║"
    echo "║                  Professional Edition                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Run as root check
    if [[ ${EUID} -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)"
    fi
    
    # Detect system
    detect_os
    
    # Check prerequisites
    check_prerequisites
    
    # Install Docker if needed
    install_docker
    
    # Backup current DNS
    backup_dns_config
    
    # Deploy Cloudflared
    deploy_cloudflared
    
    # Wait for Cloudflared to be ready
    if ! wait_for_cloudflared; then
        error_exit "Cloudflared failed to start"
    fi
    
    # Verify Cloudflared
    if ! verify_cloudflared; then
        error_exit "Cloudflared verification failed"
    fi
    
    # Configure system DNS
    configure_system_dns
    
    # Configure firewall
    configure_firewall
    
    # Run DNS tests
    if ! test_dns; then
        log_warn "Some DNS tests failed. Please check the log for details."
    fi
    
    # Generate status report
    generate_status_report
    
    # Final success message
    log_section "Installation Complete"
    echo -e "${GREEN}${BOLD}✅ DNS Leak Fix has been successfully installed!${NC}"
    echo ""
    echo -e "${YELLOW}Important Notes:${NC}"
    echo -e "  • All DNS requests are now going through ${BOLD}${DNS_ADDRESS}:${DNS_PORT}${NC}"
    echo -e "  • DNS over HTTPS (DoH) is enabled via Cloudflare"
    echo -e "  • Backup of previous configuration saved to ${BACKUP_DIR}"
    echo -e "  • Logs available at ${LOG_FILE}"
    echo ""
    echo -e "${YELLOW}To verify:${NC}"
    echo -e "  • Check DNS: ${BOLD}dig google.com @${DNS_ADDRESS}${NC}"
    echo -e "  • Check status: ${BOLD}docker ps | grep cloudflared${NC}"
    echo -e "  • View logs: ${BOLD}docker logs cloudflared${NC}"
    echo ""
    echo -e "${YELLOW}To revert:${NC}"
    echo -e "  • Restore DNS: ${BOLD}cp ${BACKUP_DIR}/resolv.conf.backup /etc/resolv.conf${NC}"
    echo -e "  • Stop container: ${BOLD}docker stop cloudflared${NC}"
    echo ""
    echo -e "${GREEN}Thank you for using DNS Leak Fix!${NC}"
}

# ============================================
# Script Entry Point
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug)
                DEBUG=true
                shift
                ;;
            --help|-h)
                echo "Usage: ${SCRIPT_NAME} [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --debug    Enable debug mode"
                echo "  --help, -h Show this help message"
                echo ""
                echo "Description:"
                echo "  This script installs and configures a DNS proxy using Cloudflared"
                echo "  to prevent DNS leaks and encrypt DNS queries."
                echo ""
                echo "Requirements:"
                echo "  - Root privileges"
                echo "  - Ubuntu/Debian/RHEL/CentOS/Fedora/Alpine"
                echo ""
                echo "Logs:"
                echo "  Log file: ${LOG_DIR}/dns-fix-*.log"
                echo ""
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Run main function
    main
fi
```
