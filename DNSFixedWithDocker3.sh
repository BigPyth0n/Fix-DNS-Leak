#!/usr/bin/env bash

# ==============================================================================
# Ubuntu 22.04 DNS Leak Protection
# Uses cloudflared proxy-dns over DNS-over-HTTPS
#
# Important:
# - This script blocks plain outbound DNS on ports 53 and 853.
# - DNS is exposed only on 127.0.0.1.
# - Cloudflare Anycast cannot guarantee that a DNS leak test shows the VPS country.
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
readonly RESOLVED_CONFIG_DIR="/etc/systemd/resolved.conf.d"
readonly RESOLVED_CONFIG="${RESOLVED_CONFIG_DIR}/90-cloudflared-dns.conf"

readonly DNS_LISTEN_ADDRESS="127.0.0.1"
readonly DNS_PORT="53"

# Cloudflare DoH upstreams.
# These are Anycast addresses and their displayed country cannot be guaranteed.
readonly DOH_UPSTREAM_1="https://1.1.1.1/dns-query"
readonly DOH_UPSTREAM_2="https://1.0.0.1/dns-query"

readonly MAX_RETRIES=30
readonly RETRY_DELAY=2

readonly IPTABLES_CHAIN="DNSFIX"
readonly IP6TABLES_CHAIN="DNSFIX"

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

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    log_error "Unexpected error at line ${line_number}; exit code: ${exit_code}"
    log_error "The system was not automatically rolled back."
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
    [[ -f /etc/os-release ]] || die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID}" == "ubuntu" ]] || \
        die "This script supports Ubuntu only."

    [[ "${VERSION_ID}" == "22.04" ]] || \
        die "This script supports Ubuntu 22.04 only."

    log_info "Operating system: ${PRETTY_NAME}"
}

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------

install_dependencies() {
    log_info "Installing required packages..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    apt-get install -y -qq \
        ca-certificates \
        curl \
        dnsutils \
        iproute2 \
        iptables \
        iptables-persistent \
        systemd-resolved \
        gpg \
        lsb-release \
        openssl

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

        cp -a --no-preserve=ownership \
            "${source_file}" \
            "${BACKUP_DIR}/${safe_name}.backup"

        log_info "Backup created: ${BACKUP_DIR}/${safe_name}.backup"
    fi
}

backup_configuration() {
    log_info "Backing up current configuration..."

    backup_file "/etc/resolv.conf"
    backup_file "/etc/systemd/resolved.conf"
    backup_file "${RESOLVED_CONFIG}"
    backup_file "/etc/iptables/rules.v4"
    backup_file "/etc/iptables/rules.v6"

    iptables-save > "${BACKUP_DIR}/iptables-before.rules"
    ip6tables-save > "${BACKUP_DIR}/ip6tables-before.rules"

    log_success "Configuration backup completed."
}

# ------------------------------------------------------------------------------
# Cloudflared Installation
# ------------------------------------------------------------------------------

install_cloudflared() {
    if [[ -x "${CLOUDFLARED_BIN}" ]]; then
        log_info "cloudflared is already installed:"
        "${CLOUDFLARED_BIN}" --version || true
        return 0
    fi

    log_info "Installing cloudflared..."

    local architecture
    architecture="$(dpkg --print-architecture)"

    local package_arch
    case "${architecture}" in
        amd64)
            package_arch="amd64"
            ;;
        arm64)
            package_arch="arm64"
            ;;
        armhf)
            package_arch="arm"
            ;;
        *)
            die "Unsupported CPU architecture: ${architecture}"
            ;;
    esac

    local download_url
    download_url="$(
        curl -fsSL \
        "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" |
        grep -m1 "browser_download_url.*linux-${package_arch}" |
        cut -d '"' -f 4
    )"

    [[ -n "${download_url}" ]] || \
        die "Could not determine the latest cloudflared download URL."

    curl -fL --retry 5 --connect-timeout 15 \
        "${download_url}" \
        -o "${CLOUDFLARED_BIN}"

    chmod 0755 "${CLOUDFLARED_BIN}"

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
    fi
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
    --address ${DNS_LISTEN_ADDRESS} \\
    --port ${DNS_PORT} \\
    --upstream ${DOH_UPSTREAM_1} \\
    --upstream ${DOH_UPSTREAM_2} \\
    --no-autoupdate

Restart=always
RestartSec=5

# Hardening
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
# systemd-resolved Configuration
# ------------------------------------------------------------------------------

configure_systemd_resolved() {
    log_info "Configuring systemd-resolved..."

    mkdir -p "${RESOLVED_CONFIG_DIR}"

    cat > "${RESOLVED_CONFIG}" <<EOF
[Resolve]
DNS=${DNS_LISTEN_ADDRESS}
FallbackDNS=
Domains=~.
DNSStubListener=yes
DNSStubListenerExtra=
EOF

    chmod 0644 "${RESOLVED_CONFIG}"

    # Ensure systemd-resolved is enabled and running.
    systemctl enable systemd-resolved
    systemctl restart systemd-resolved

    # Use the systemd-resolved local stub.
    # Applications query 127.0.0.53, and resolved forwards only to
    # cloudflared at 127.0.0.1.
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    systemctl restart systemd-resolved

    log_success "systemd-resolved configured to use local cloudflared."
}

# ------------------------------------------------------------------------------
# Firewall
# ------------------------------------------------------------------------------

remove_iptables_jump_if_exists() {
    local command_name="$1"
    local chain="$2"

    while "${command_name}" -C OUTPUT -j "${chain}" >/dev/null 2>&1; do
        "${command_name}" -D OUTPUT -j "${chain}" || true
    done
}

configure_ipv4_firewall() {
    log_info "Configuring IPv4 DNS firewall rules..."

    remove_iptables_jump_if_exists iptables "${IPTABLES_CHAIN}"

    iptables -N "${IPTABLES_CHAIN}" 2>/dev/null || true
    iptables -F "${IPTABLES_CHAIN}"

    # Never block loopback traffic.
    iptables -A "${IPTABLES_CHAIN}" -o lo -j RETURN

    # Block direct plain DNS and DNS-over-TLS.
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 853 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 853 -j DROP

    iptables -I OUTPUT 1 -j "${IPTABLES_CHAIN}"

    log_success "IPv4 direct DNS traffic blocked."
}

configure_ipv6_firewall() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        log_warn "ip6tables is not available."
        return 0
    fi

    log_info "Configuring IPv6 DNS firewall rules..."

    remove_iptables_jump_if_exists ip6tables "${IP6TABLES_CHAIN}"

    ip6tables -N "${IP6TABLES_CHAIN}" 2>/dev/null || true
    ip6tables -F "${IP6TABLES_CHAIN}"

    ip6tables -A "${IP6TABLES_CHAIN}" -o lo -j RETURN

    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 853 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 853 -j DROP

    ip6tables -I OUTPUT 1 -j "${IP6TABLES_CHAIN}"

    log_success "IPv6 direct DNS traffic blocked."
}

save_firewall_rules() {
    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4

    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6
    fi

    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    systemctl restart netfilter-persistent >/dev/null 2>&1 || true

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
    log_info "Waiting for local DNS proxy..."

    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if ss -H -lntu | grep -Eq \
            "(127\.0\.0\.1|\[?::1\]?):53[[:space:]]"; then
            log_success "A local DNS listener is active."
            return 0
        fi

        log_debug "DNS listener is not ready; attempt ${attempt}/${MAX_RETRIES}"
        sleep "${RETRY_DELAY}"
        attempt=$((attempt + 1))
    done

    systemctl status cloudflared-dns.service --no-pager || true
    journalctl -u cloudflared-dns.service -n 50 --no-pager || true

    die "Local cloudflared DNS proxy did not start."
}

test_local_dns() {
    log_info "Testing DNS through local resolver..."

    local domain="example.com"

    if ! dig \
        +time=5 \
        +tries=2 \
        @"${DNS_LISTEN_ADDRESS}" \
        "${domain}" \
        +short | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then

        dig @"${DNS_LISTEN_ADDRESS}" "${domain}" || true
        die "UDP DNS test failed."
    fi

    log_success "UDP DNS test passed."
}

test_tcp_dns() {
    log_info "Testing DNS over TCP..."

    if dig \
        +tcp \
        +time=5 \
        +tries=2 \
        @"${DNS_LISTEN_ADDRESS}" \
        example.com \
        +short >/dev/null; then

        log_success "TCP DNS test passed."
    else
        die "TCP DNS test failed."
    fi
}

test_doh_process() {
    log_info "Checking cloudflared DoH proxy..."

    if ! systemctl is-active --quiet cloudflared-dns.service; then
        systemctl status cloudflared-dns.service --no-pager || true
        die "cloudflared-dns.service is not active."
    fi

    if ! pgrep -fa cloudflared | grep -q "proxy-dns"; then
        die "cloudflared proxy-dns process was not found."
    fi

    log_success "cloudflared DoH proxy is active."
}

test_no_plain_dns_rules() {
    log_info "Checking firewall DNS blocking rules..."

    local v4_ok=false
    local v6_ok=false

    if iptables -S "${IPTABLES_CHAIN}" 2>/dev/null |
        grep -Eq -- '--dport (53|853).*DROP'; then
        v4_ok=true
    fi

    if command -v ip6tables >/dev/null 2>&1 &&
        ip6tables -S "${IP6TABLES_CHAIN}" 2>/dev/null |
        grep -Eq -- '--dport (53|853).*DROP'; then
        v6_ok=true
    fi

    [[ "${v4_ok}" == true ]] ||
        die "IPv4 plain DNS blocking rules are missing."

    if [[ -e /proc/net/if_inet6 ]]; then
        [[ "${v6_ok}" == true ]] ||
            die "IPv6 plain DNS blocking rules are missing."
    fi

    log_success "Plain outbound DNS blocking rules are active."
}

show_status() {
    echo
    echo "======================================================================"
    echo "DNS STATUS"
    echo "======================================================================"

    echo "cloudflared service:"
    systemctl is-active cloudflared-dns.service || true

    echo
    echo "systemd-resolved:"
    systemctl is-active systemd-resolved || true

    echo
    echo "Current resolv.conf:"
    cat /etc/resolv.conf

    echo
    echo "Listening DNS sockets:"
    ss -lntu | grep -E '(:53[[:space:]]|:53$)' || true

    echo
    echo "Local DNS result:"
    dig @"${DNS_LISTEN_ADDRESS}" example.com +short || true

    echo
    echo "VPS public IPv4:"
    curl -4fsS --max-time 10 https://api.ipify.org || true
    echo

    echo
    echo "VPS public IPv6:"
    curl -6fsS --max-time 10 https://api6.ipify.org 2>/dev/null || true
    echo

    echo
    echo "Firewall DNS rules:"
    iptables -S "${IPTABLES_CHAIN}" 2>/dev/null || true
    ip6tables -S "${IP6TABLES_CHAIN}" 2>/dev/null || true

    echo
    echo "Backup directory:"
    echo "${BACKUP_DIR}"

    echo
    echo "Log file:"
    echo "${LOG_FILE}"

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
    configure_systemd_resolved
    configure_firewall

    test_doh_process
    test_local_dns
    test_tcp_dns
    test_no_plain_dns_rules

    show_status

    log_success "DNS Leak protection configuration completed."
    log_warn "Cloudflare Anycast cannot guarantee that DNS Leak Test displays the VPS country."
    log_info "For external verification, use browser-based DNS Leak Test from the VPS network."
}

main "$@"
