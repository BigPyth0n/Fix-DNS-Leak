#!/usr/bin/env bash

# ==============================================================================
# Ubuntu DNS Leak Protection
#
# Architecture:
#   Applications -> 127.0.0.1:53 -> cloudflared -> DNS-over-HTTPS -> Cloudflare
#
# This script:
#   - Does not install systemd-resolved.
#   - Runs cloudflared directly on 127.0.0.1:53.
#   - Blocks outbound plain DNS and DNS-over-TLS on ports 53 and 853.
#   - Saves IPv4 and IPv6 firewall rules persistently.
#
# Important:
#   - This protects against direct DNS traffic on ports 53 and 853.
#   - Applications using their own DoH/DoT implementation may bypass this setup.
#   - Cloudflare Anycast cannot guarantee that DNS leak tests show the VPS country.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"

readonly BASE_DIR="/etc/dns-fix"
readonly BACKUP_DIR="${BASE_DIR}/backup"
readonly LOG_DIR="/var/log/dns-fix"
readonly LOG_FILE="${LOG_DIR}/dns-fix-$(date +%Y%m%d_%H%M%S).log"

readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared-dns.service"

readonly DNS_ADDRESS="127.0.0.1"
readonly DNS_PORT="53"

readonly DOH_UPSTREAM_1="https://1.1.1.1/dns-query"
readonly DOH_UPSTREAM_2="https://1.0.0.1/dns-query"

readonly IPTABLES_CHAIN="DNSFIX"
readonly IP6TABLES_CHAIN="DNSFIX"

readonly MAX_RETRIES=30
readonly RETRY_DELAY=2

DEBUG="${DEBUG:-false}"

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    echo -e "${C_GREEN}[INFO]${C_RESET} $(timestamp) - $*"
}

log_warn() {
    echo -e "${C_YELLOW}[WARN]${C_RESET} $(timestamp) - $*"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $(timestamp) - $*" >&2
}

log_success() {
    echo -e "${C_GREEN}${C_BOLD}[SUCCESS]${C_RESET} $(timestamp) - $*"
}

log_debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        echo -e "${C_CYAN}[DEBUG]${C_RESET} $(timestamp) - $*"
    fi
}

die() {
    log_error "$*"
    exit 1
}

init_logging() {
    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"

    touch "${LOG_FILE}"
    chmod 0600 "${LOG_FILE}"

    exec > >(tee -a "${LOG_FILE}") 2>&1

    echo "======================================================================"
    echo "DNS Fix started: $(date --iso-8601=seconds)"
    echo "Script: ${SCRIPT_NAME}"
    echo "Log: ${LOG_FILE}"
    echo "======================================================================"
}

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    log_error "Unexpected error at line ${line_number}; exit code: ${exit_code}"
    log_error "Automatic rollback was not performed."
    log_error "Review the log file: ${LOG_FILE}"

    exit "${exit_code}"
}

on_interrupt() {
    log_warn "Script interrupted by user."
    exit 130
}

trap 'on_error "${LINENO}"' ERR
trap on_interrupt INT TERM

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This script must be run as root."
}

validate_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release was not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || {
        die "This script supports Ubuntu only."
    }

    [[ "${VERSION_ID:-}" == "22.04" ]] || {
        die "This script supports Ubuntu 22.04 only."
    }

    log_info "Operating system: ${PRETTY_NAME}"
}

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------

install_dependencies() {
    log_info "Installing required packages..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    # Disable interactive prompts from iptables-persistent.
    if command -v debconf-set-selections >/dev/null 2>&1; then
        debconf-set-selections <<'EOF'
iptables-persistent iptables-persistent/autosave_v4 boolean false
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF
    fi

    apt-get install -y -qq \
        ca-certificates \
        curl \
        dnsutils \
        iproute2 \
        iptables \
        iptables-persistent \
        openssl \
        systemd

    # systemd-resolved is intentionally not installed.
    log_success "Required packages installed."
}

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------

backup_file() {
    local source_file="$1"

    if [[ -e "${source_file}" || -L "${source_file}" ]]; then
        local safe_name
        safe_name="$(echo "${source_file}" | sed 's#^/##; s#/#_#g')"

        cp -a \
            --no-preserve=ownership \
            "${source_file}" \
            "${BACKUP_DIR}/${safe_name}.backup"

        log_info "Backup created: ${BACKUP_DIR}/${safe_name}.backup"
    fi
}

backup_configuration() {
    log_info "Backing up current configuration..."

    backup_file "/etc/resolv.conf"
    backup_file "/etc/systemd/resolved.conf"
    backup_file "/etc/systemd/system/cloudflared-dns.service"
    backup_file "/etc/iptables/rules.v4"
    backup_file "/etc/iptables/rules.v6"

    iptables-save > "${BACKUP_DIR}/iptables-before.rules"

    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "${BACKUP_DIR}/ip6tables-before.rules" || true
    fi

    log_success "Configuration backup completed."
}

# ------------------------------------------------------------------------------
# Cloudflared Installation
# ------------------------------------------------------------------------------

get_cloudflared_architecture() {
    local architecture
    architecture="$(dpkg --print-architecture)"

    case "${architecture}" in
        amd64)
            echo "amd64"
            ;;
        arm64)
            echo "arm64"
            ;;
        armhf)
            echo "arm"
            ;;
        *)
            die "Unsupported CPU architecture: ${architecture}"
            ;;
    esac
}

install_cloudflared() {
    if [[ -x "${CLOUDFLARED_BIN}" ]]; then
        log_info "cloudflared is already installed."
        "${CLOUDFLARED_BIN}" --version || true
        return 0
    fi

    log_info "Installing cloudflared..."

    local package_arch
    package_arch="$(get_cloudflared_architecture)"

    local download_url
    download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${package_arch}"

    local temporary_file
    temporary_file="$(mktemp)"

    curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 180 \
        "${download_url}" \
        -o "${temporary_file}"

    [[ -s "${temporary_file}" ]] || {
        rm -f "${temporary_file}"
        die "Downloaded cloudflared file is empty."
    }

    install -o root -g root -m 0755 \
        "${temporary_file}" \
        "${CLOUDFLARED_BIN}"

    rm -f "${temporary_file}"

    "${CLOUDFLARED_BIN}" --version

    log_success "cloudflared installed."
}

# ------------------------------------------------------------------------------
# Dedicated User
# ------------------------------------------------------------------------------

create_cloudflared_user() {
    if ! id cloudflared >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir /var/lib/cloudflared \
            --create-home \
            --shell /usr/sbin/nologin \
            cloudflared

        log_info "Created system user: cloudflared"
    else
        log_info "System user cloudflared already exists."
    fi

    install -d \
        -o cloudflared \
        -g cloudflared \
        -m 0750 \
        /var/lib/cloudflared
}

# ------------------------------------------------------------------------------
# cloudflared Systemd Service
# ------------------------------------------------------------------------------

create_cloudflared_service() {
    log_info "Creating cloudflared systemd service..."

    cat > "${CLOUDFLARED_SERVICE}" <<EOF
[Unit]
Description=Cloudflared DNS-over-HTTPS Local Proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cloudflared
Group=cloudflared

ExecStart=${CLOUDFLARED_BIN} proxy-dns \\
    --address ${DNS_ADDRESS} \\
    --port ${DNS_PORT} \\
    --upstream ${DOH_UPSTREAM_1} \\
    --upstream ${DOH_UPSTREAM_2} \\
    --no-autoupdate

Restart=always
RestartSec=5
TimeoutStartSec=30

# Required to bind to port 53 as a non-root user.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Security hardening.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=/var/lib/cloudflared

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${CLOUDFLARED_SERVICE}"

    systemctl daemon-reload
    systemctl enable cloudflared-dns.service
    systemctl restart cloudflared-dns.service

    log_success "cloudflared service started."
}

# ------------------------------------------------------------------------------
# Resolver Configuration
# ------------------------------------------------------------------------------

disable_systemd_resolved_if_present() {
    if systemctl list-unit-files \
        --type=service \
        --no-legend \
        2>/dev/null |
        awk '{print $1}' |
        grep -qx "systemd-resolved.service"; then

        log_info "Stopping systemd-resolved because cloudflared owns 127.0.0.1:53..."

        systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
    fi
}

configure_resolver() {
    log_info "Configuring /etc/resolv.conf..."

    disable_systemd_resolved_if_present

    # Remove an existing file or symlink.
    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<EOF
# Managed by ${SCRIPT_NAME}
# Local DNS-over-HTTPS resolver
nameserver ${DNS_ADDRESS}
options timeout:2 attempts:3
EOF

    chmod 0644 /etc/resolv.conf

    log_success "/etc/resolv.conf now uses ${DNS_ADDRESS}."
}

# ------------------------------------------------------------------------------
# Firewall Helpers
# ------------------------------------------------------------------------------

remove_iptables_jump_if_exists() {
    local command_name="$1"
    local chain="$2"

    while "${command_name}" -C OUTPUT -j "${chain}" >/dev/null 2>&1; do
        "${command_name}" -D OUTPUT -j "${chain}" || true
    done
}

chain_exists() {
    local command_name="$1"
    local chain="$2"

    "${command_name}" -nL "${chain}" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# IPv4 Firewall
# ------------------------------------------------------------------------------

configure_ipv4_firewall() {
    log_info "Configuring IPv4 DNS firewall rules..."

    remove_iptables_jump_if_exists iptables "${IPTABLES_CHAIN}"

    if ! chain_exists iptables "${IPTABLES_CHAIN}"; then
        iptables -N "${IPTABLES_CHAIN}"
    fi

    iptables -F "${IPTABLES_CHAIN}"

    # Permit loopback traffic.
    iptables -A "${IPTABLES_CHAIN}" -o lo -j RETURN

    # Block direct DNS and DNS-over-TLS.
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 853 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 853 -j DROP

    # Insert at the top so later ACCEPT rules cannot bypass it.
    iptables -I OUTPUT 1 -j "${IPTABLES_CHAIN}"

    log_success "IPv4 direct DNS traffic blocked."
}

# ------------------------------------------------------------------------------
# IPv6 Firewall
# ------------------------------------------------------------------------------

configure_ipv6_firewall() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        log_warn "ip6tables is not available; skipping IPv6 firewall rules."
        return 0
    fi

    if [[ ! -e /proc/net/if_inet6 ]]; then
        log_warn "IPv6 is disabled; skipping IPv6 firewall rules."
        return 0
    fi

    log_info "Configuring IPv6 DNS firewall rules..."

    remove_iptables_jump_if_exists ip6tables "${IP6TABLES_CHAIN}"

    if ! chain_exists ip6tables "${IP6TABLES_CHAIN}"; then
        ip6tables -N "${IP6TABLES_CHAIN}"
    fi

    ip6tables -F "${IP6TABLES_CHAIN}"

    # Permit loopback traffic.
    ip6tables -A "${IP6TABLES_CHAIN}" -o lo -j RETURN

    # Block direct DNS and DNS-over-TLS.
    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 853 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 853 -j DROP

    ip6tables -I OUTPUT 1 -j "${IP6TABLES_CHAIN}"

    log_success "IPv6 direct DNS traffic blocked."
}

save_firewall_rules() {
    log_info "Saving firewall rules..."

    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4

    if command -v ip6tables-save >/dev/null 2>&1 &&
        [[ -e /proc/net/if_inet6 ]]; then
        ip6tables-save > /etc/iptables/rules.v6 || true
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        systemctl enable netfilter-persistent >/dev/null 2>&1 || true
        systemctl restart netfilter-persistent >/dev/null 2>&1 || true
    fi

    log_success "Firewall rules saved persistently."
}

configure_firewall() {
    configure_ipv4_firewall
    configure_ipv6_firewall
    save_firewall_rules
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

wait_for_local_dns() {
    log_info "Waiting for cloudflared local DNS listener..."

    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if ss -H -lntu 2>/dev/null |
            awk '$4 ~ /^127\.0\.0\.1:53$/ {found=1} END {exit !found}'; then

            log_success "DNS listener is active on ${DNS_ADDRESS}:${DNS_PORT}."
            return 0
        fi

        log_debug "DNS listener is not ready; attempt ${attempt}/${MAX_RETRIES}"
        sleep "${RETRY_DELAY}"
        attempt=$((attempt + 1))
    done

    systemctl status cloudflared-dns.service --no-pager || true
    journalctl -u cloudflared-dns.service -n 50 --no-pager || true

    die "cloudflared DNS listener did not start."
}

test_cloudflared_service() {
    log_info "Checking cloudflared service..."

    if ! systemctl is-active --quiet cloudflared-dns.service; then
        systemctl status cloudflared-dns.service --no-pager || true
        die "cloudflared-dns.service is not active."
    fi

    log_success "cloudflared-dns.service is active."
}

test_local_dns_udp() {
    log_info "Testing local DNS over UDP..."

    if ! dig \
        +time=5 \
        +tries=2 \
        @"${DNS_ADDRESS}" \
        example.com \
        +short |
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then

        dig @"${DNS_ADDRESS}" example.com || true
        die "UDP DNS test failed."
    fi

    log_success "UDP DNS test passed."
}

test_local_dns_tcp() {
    log_info "Testing local DNS over TCP..."

    if ! dig \
        +tcp \
        +time=5 \
        +tries=2 \
        @"${DNS_ADDRESS}" \
        example.com \
        +short >/dev/null; then

        die "TCP DNS test failed."
    fi

    log_success "TCP DNS test passed."
}

test_resolv_conf() {
    log_info "Checking /etc/resolv.conf..."

    if ! grep -Eq \
        "^[[:space:]]*nameserver[[:space:]]+${DNS_ADDRESS//./\\.}([[:space:]]*)$" \
        /etc/resolv.conf; then

        cat /etc/resolv.conf
        die "/etc/resolv.conf is not configured to use ${DNS_ADDRESS}."
    fi

    log_success "/etc/resolv.conf is correctly configured."
}

test_firewall_rules() {
    log_info "Checking DNS blocking firewall rules..."

    local v4_ok=false
    local v6_ok=false

    if iptables -S "${IPTABLES_CHAIN}" 2>/dev/null |
        grep -Eq -- '--dport (53|853).*DROP'; then
        v4_ok=true
    fi

    [[ "${v4_ok}" == true ]] ||
        die "IPv4 DNS blocking rules are missing."

    if command -v ip6tables >/dev/null 2>&1 &&
        [[ -e /proc/net/if_inet6 ]] &&
        ip6tables -S "${IP6TABLES_CHAIN}" 2>/dev/null |
        grep -Eq -- '--dport (53|853).*DROP'; then
        v6_ok=true
    fi

    if [[ -e /proc/net/if_inet6 ]]; then
        [[ "${v6_ok}" == true ]] ||
            die "IPv6 DNS blocking rules are missing."
    fi

    log_success "Direct outbound DNS blocking rules are active."
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------

show_status() {
    echo
    echo "======================================================================"
    echo "DNS STATUS"
    echo "======================================================================"

    echo
    echo "cloudflared service:"
    systemctl is-active cloudflared-dns.service || true

    echo
    echo "Current resolv.conf:"
    cat /etc/resolv.conf

    echo
    echo "Listening DNS sockets:"
    ss -lntu 2>/dev/null |
        grep -E '127\.0\.0\.1:53([[:space:]]|$)' || true

    echo
    echo "Local DNS result:"
    dig @"${DNS_ADDRESS}" example.com +short || true

    echo
    echo "VPS public IPv4:"
    curl -4fsS --max-time 10 https://api.ipify.org || true
    echo

    echo
    echo "VPS public IPv6:"
    curl -6fsS --max-time 10 https://api6.ipify.org 2>/dev/null || true
    echo

    echo
    echo "IPv4 firewall rules:"
    iptables -S "${IPTABLES_CHAIN}" 2>/dev/null || true

    echo
    echo "IPv6 firewall rules:"
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -S "${IP6TABLES_CHAIN}" 2>/dev/null || true
    fi

    echo
    echo "Backup directory:"
    echo "${BACKUP_DIR}"

    echo
    echo "Log file:"
    echo "${LOG_FILE}"

    echo
    echo "======================================================================"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    init_logging

    require_root
    validate_os
    install_dependencies
    backup_configuration

    install_cloudflared
    create_cloudflared_user
    create_cloudflared_service

    wait_for_local_dns
    configure_resolver
    configure_firewall

    test_cloudflared_service
    test_resolv_conf
    test_local_dns_udp
    test_local_dns_tcp
    test_firewall_rules

    show_status

    log_success "DNS leak protection configuration completed."
    log_warn "Cloudflare Anycast cannot guarantee that DNS leak tests show the VPS country."
    log_warn "This script does not block applications that implement their own DoH or VPN tunnel."
}

main "$@"
