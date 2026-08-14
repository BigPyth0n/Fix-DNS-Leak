#!/usr/bin/env bash

# ==============================================================================
# Ubuntu 22.04 DNS-over-HTTPS Leak Protection
#
# Architecture:
#
#   Applications
#       |
#       v
#   127.0.0.1:53
#       |
#       v
#   dnscrypt-proxy 2.0.45+
#       |
#       v
#   DNS-over-HTTPS
#       |
#       v
#   Cloudflare DNS
#
# Features:
#   - Uses dnscrypt-proxy instead of deprecated cloudflared proxy-dns.
#   - Removes old cloudflared-dns.service.
#   - Disables and masks dnscrypt-proxy.socket to prevent port conflicts.
#   - Listens only on 127.0.0.1:53.
#   - Uses Cloudflare DNS-over-HTTPS.
#   - Blocks direct outbound DNS on ports 53 and 853.
#   - Configures IPv4 and IPv6 firewall rules.
#   - Saves firewall rules persistently.
#   - Creates backups before changing files.
#   - Shows a final summary table.
#
# Important:
#   - Applications with their own DoH, DoT, VPN or proxy can bypass this setup.
#   - Cloudflare Anycast cannot guarantee the country shown in DNS leak tests.
#   - This script modifies /etc/resolv.conf and firewall OUTPUT rules.
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

readonly DNS_ADDRESS="127.0.0.1"
readonly DNS_PORT="53"

readonly DNSCRYPT_SERVICE="dnscrypt-proxy.service"
readonly DNSCRYPT_SOCKET="dnscrypt-proxy.socket"
readonly DNSCRYPT_CONFIG_DIR="/etc/dnscrypt-proxy"
readonly DNSCRYPT_CONFIG="${DNSCRYPT_CONFIG_DIR}/dnscrypt-proxy.toml"
readonly DNSCRYPT_CACHE_DIR="/var/cache/dnscrypt-proxy"
readonly DNSCRYPT_STATE_DIR="/var/lib/dnscrypt-proxy"
readonly DNSCRYPT_SERVICE_FILE="/etc/systemd/system/dnscrypt-proxy.service"
readonly DNSCRYPT_BINARY="/usr/sbin/dnscrypt-proxy"

readonly CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared-dns.service"

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
# Report Variables
# ------------------------------------------------------------------------------

REPORT_SERVICE="FAILED"
REPORT_LISTENER="FAILED"
REPORT_RESOLV="FAILED"
REPORT_UDP="FAILED"
REPORT_TCP="FAILED"
REPORT_IPV4_FIREWALL="FAILED"
REPORT_IPV6_FIREWALL="SKIPPED"
REPORT_PERSISTENCE="FAILED"
REPORT_DNSCRYPT_VERSION="UNKNOWN"

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
    [[ "${EUID}" -eq 0 ]] || {
        die "This script must be run as root."
    }
}

validate_os() {
    [[ -f /etc/os-release ]] || {
        die "/etc/os-release was not found."
    }

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

validate_commands() {
    local required_command

    for required_command in \
        awk \
        curl \
        dig \
        grep \
        id \
        install \
        iptables \
        iptables-save \
        sed \
        ss \
        systemctl \
        useradd; do

        command -v "${required_command}" >/dev/null 2>&1 || {
            die "Required command not found: ${required_command}"
        }
    done

    [[ -x "${DNSCRYPT_BINARY}" ]] || {
        DNSCRYPT_BINARY="$(command -v dnscrypt-proxy || true)"

        [[ -n "${DNSCRYPT_BINARY}" ]] || {
            die "dnscrypt-proxy binary was not found."
        }
    }
}

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------

install_dependencies() {
    log_info "Installing required packages..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    if command -v debconf-set-selections >/dev/null 2>&1; then
        debconf-set-selections <<'EOF'
iptables-persistent iptables-persistent/autosave_v4 boolean false
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF
    fi

    apt-get install -y -qq \
        ca-certificates \
        curl \
        dnscrypt-proxy \
        dnsutils \
        iproute2 \
        iptables \
        iptables-persistent \
        systemd

    log_success "Required packages installed."
}

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------

backup_file() {
    local source_file="$1"

    if [[ -e "${source_file}" || -L "${source_file}" ]]; then
        local safe_name

        safe_name="$(echo "${source_file}" |
            sed 's#^/##; s#/#_#g')"

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
    backup_file "${CLOUDFLARED_SERVICE_FILE}"
    backup_file "${DNSCRYPT_CONFIG}"
    backup_file "${DNSCRYPT_SERVICE_FILE}"
    backup_file "/etc/iptables/rules.v4"
    backup_file "/etc/iptables/rules.v6"

    iptables-save > "${BACKUP_DIR}/iptables-before.rules"

    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "${BACKUP_DIR}/ip6tables-before.rules" || true
    fi

    log_success "Configuration backup completed."
}

# ------------------------------------------------------------------------------
# Remove Old Services
# ------------------------------------------------------------------------------

remove_old_cloudflared() {
    log_info "Removing old cloudflared DNS service..."

    systemctl disable --now cloudflared-dns.service \
        >/dev/null 2>&1 || true

    rm -f "${CLOUDFLARED_SERVICE_FILE}"

    systemctl daemon-reload

    log_success "Old cloudflared service removed."
}

disable_systemd_resolved() {
    if systemctl list-unit-files \
        --type=service \
        --no-legend \
        2>/dev/null |
        awk '{print $1}' |
        grep -qx "systemd-resolved.service"; then

        log_info "Disabling systemd-resolved..."

        systemctl disable --now systemd-resolved.service \
            >/dev/null 2>&1 || true
    fi
}

disable_dnscrypt_socket() {
    log_info "Disabling dnscrypt-proxy socket activation..."

    # Stop the package-provided socket because it may listen on 127.0.2.1:53.
    systemctl disable --now "${DNSCRYPT_SOCKET}" \
        >/dev/null 2>&1 || true

    # Mask it so that it cannot be started automatically again.
    systemctl mask "${DNSCRYPT_SOCKET}" \
        >/dev/null 2>&1 || true

    # Stop any package-provided service instance before using our own unit.
    systemctl stop "${DNSCRYPT_SERVICE}" \
        >/dev/null 2>&1 || true

    systemctl daemon-reload

    log_success "dnscrypt-proxy.socket disabled and masked."
}

# ------------------------------------------------------------------------------
# dnscrypt-proxy User and Directories
# ------------------------------------------------------------------------------

create_dnscrypt_user() {
    if ! id dnscrypt >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir "${DNSCRYPT_STATE_DIR}" \
            --create-home \
            --shell /usr/sbin/nologin \
            dnscrypt

        log_info "Created system user: dnscrypt"
    else
        log_info "System user dnscrypt already exists."
    fi

    install -d \
        -o dnscrypt \
        -g dnscrypt \
        -m 0750 \
        "${DNSCRYPT_STATE_DIR}"

    install -d \
        -o dnscrypt \
        -g dnscrypt \
        -m 0750 \
        "${DNSCRYPT_CACHE_DIR}"

    install -d \
        -o root \
        -g root \
        -m 0755 \
        "${DNSCRYPT_CONFIG_DIR}"
}

# ------------------------------------------------------------------------------
# dnscrypt-proxy Configuration
# ------------------------------------------------------------------------------

configure_dnscrypt_proxy() {
    log_info "Creating dnscrypt-proxy configuration..."

    if [[ -f "${DNSCRYPT_CONFIG}" ]]; then
        cp -a \
            "${DNSCRYPT_CONFIG}" \
            "${BACKUP_DIR}/dnscrypt-proxy.toml.before-script"
    fi

    cat > "${DNSCRYPT_CONFIG}" <<'EOF'
# ============================================================================
# dnscrypt-proxy configuration
# Compatible with dnscrypt-proxy 2.0.45
# Managed by dns-fix
# ============================================================================

# Listen only locally.
listen_addresses = ['127.0.0.1:53']

# Use Cloudflare only.
server_names = ['cloudflare']

# Enable DNS-over-HTTPS.
doh_servers = true

# Disable DNSCrypt protocol.
dnscrypt_servers = false

# Do not use IPv6 upstream servers.
ipv4_servers = true
ipv6_servers = false

# DNSSEC settings.
# NOTE:
# require_min_protocol is intentionally omitted because dnscrypt-proxy 2.0.45
# does not support that configuration key.
require_dnssec = true
require_nofilter = false

# Local DNS cache.
cache = true
cache_size = 512
cache_min_ttl = 60
cache_max_ttl = 86400

# Never use plain DNS as a fallback.
fallback_resolvers = []

# Bootstrap resolvers are used for resolver discovery.
# Direct outbound port 53 is blocked after startup.
bootstrap_resolvers = ['1.1.1.1:53', '1.0.0.1:53']

# Network timeouts.
timeout = 5000
keepalive = 30

# Ignore the system resolver.
ignore_system_dns = true

# Resolver list sources.
[sources]

[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md'
]
cache = '/var/cache/dnscrypt-proxy/public-resolvers.md'

[sources.relays]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md'
]
cache = '/var/cache/dnscrypt-proxy/relays.md'
EOF

    chown root:root "${DNSCRYPT_CONFIG}"
    chmod 0644 "${DNSCRYPT_CONFIG}"

    log_success "dnscrypt-proxy configuration created."
}

# ------------------------------------------------------------------------------
# dnscrypt-proxy systemd Service
# ------------------------------------------------------------------------------

create_dnscrypt_service() {
    log_info "Creating custom dnscrypt-proxy service..."

    cat > "${DNSCRYPT_SERVICE_FILE}" <<EOF
[Unit]
Description=DNS-over-HTTPS Local Resolver via dnscrypt-proxy
Wants=network-online.target
After=network-online.target
Conflicts=${DNSCRYPT_SOCKET}

[Service]
Type=simple
User=dnscrypt
Group=dnscrypt

ExecStart=${DNSCRYPT_BINARY} -config ${DNSCRYPT_CONFIG}

Restart=on-failure
RestartSec=5
TimeoutStartSec=60

# Allow non-root process to bind to port 53.
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

ReadOnlyPaths=${DNSCRYPT_CONFIG}
ReadWritePaths=${DNSCRYPT_CACHE_DIR} ${DNSCRYPT_STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${DNSCRYPT_SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${DNSCRYPT_SERVICE}"

    log_success "Custom dnscrypt-proxy service created."
}

# ------------------------------------------------------------------------------
# Resolver Configuration
# ------------------------------------------------------------------------------

configure_resolv_conf() {
    log_info "Configuring /etc/resolv.conf..."

    disable_systemd_resolved

    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<EOF
# Managed by ${SCRIPT_NAME}
# DNS-over-HTTPS local resolver
nameserver ${DNS_ADDRESS}
options timeout:2 attempts:3
EOF

    chmod 0644 /etc/resolv.conf

    log_success "/etc/resolv.conf now uses ${DNS_ADDRESS}."
}

# ------------------------------------------------------------------------------
# Firewall Helpers
# ------------------------------------------------------------------------------

chain_exists() {
    local command_name="$1"
    local chain_name="$2"

    "${command_name}" -nL "${chain_name}" >/dev/null 2>&1
}

remove_output_jump() {
    local command_name="$1"
    local chain_name="$2"

    while "${command_name}" -C OUTPUT -j "${chain_name}" \
        >/dev/null 2>&1; do

        "${command_name}" -D OUTPUT -j "${chain_name}" || true
    done
}

# ------------------------------------------------------------------------------
# IPv4 Firewall
# ------------------------------------------------------------------------------

configure_ipv4_firewall() {
    log_info "Configuring IPv4 firewall rules..."

    remove_output_jump iptables "${IPTABLES_CHAIN}"

    if ! chain_exists iptables "${IPTABLES_CHAIN}"; then
        iptables -N "${IPTABLES_CHAIN}"
    fi

    iptables -F "${IPTABLES_CHAIN}"

    # Allow loopback traffic.
    iptables -A "${IPTABLES_CHAIN}" -o lo -j RETURN

    # Block direct DNS and DNS-over-TLS.
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 53 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p udp --dport 853 -j DROP
    iptables -A "${IPTABLES_CHAIN}" -p tcp --dport 853 -j DROP

    # Put the chain at the top of OUTPUT.
    iptables -I OUTPUT 1 -j "${IPTABLES_CHAIN}"

    log_success "IPv4 DNS and DoT traffic blocked."
}

# ------------------------------------------------------------------------------
# IPv6 Firewall
# ------------------------------------------------------------------------------

configure_ipv6_firewall() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        log_warn "ip6tables is not installed; IPv6 rules skipped."
        REPORT_IPV6_FIREWALL="SKIPPED"
        return 0
    fi

    if [[ ! -e /proc/net/if_inet6 ]]; then
        log_warn "IPv6 is disabled; IPv6 rules skipped."
        REPORT_IPV6_FIREWALL="SKIPPED"
        return 0
    fi

    log_info "Configuring IPv6 firewall rules..."

    remove_output_jump ip6tables "${IP6TABLES_CHAIN}"

    if ! chain_exists ip6tables "${IP6TABLES_CHAIN}"; then
        ip6tables -N "${IP6TABLES_CHAIN}"
    fi

    ip6tables -F "${IP6TABLES_CHAIN}"

    # Allow loopback traffic.
    ip6tables -A "${IP6TABLES_CHAIN}" -o lo -j RETURN

    # Block direct DNS and DNS-over-TLS.
    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 53 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p udp --dport 853 -j DROP
    ip6tables -A "${IP6TABLES_CHAIN}" -p tcp --dport 853 -j DROP

    ip6tables -I OUTPUT 1 -j "${IP6TABLES_CHAIN}"

    REPORT_IPV6_FIREWALL="PASS"

    log_success "IPv6 DNS and DoT traffic blocked."
}

save_firewall_rules() {
    log_info "Saving firewall rules persistently..."

    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4

    if command -v ip6tables-save >/dev/null 2>&1 &&
        [[ -e /proc/net/if_inet6 ]]; then

        ip6tables-save > /etc/iptables/rules.v6
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        systemctl enable netfilter-persistent \
            >/dev/null 2>&1 || true

        systemctl restart netfilter-persistent \
            >/dev/null 2>&1 || true
    fi

    REPORT_PERSISTENCE="PASS"

    log_success "Firewall rules saved persistently."
}

configure_firewall() {
    configure_ipv4_firewall
    configure_ipv6_firewall
    save_firewall_rules
}

# ------------------------------------------------------------------------------
# Service Control
# ------------------------------------------------------------------------------

start_dnscrypt_service() {
    log_info "Starting dnscrypt-proxy service..."

    systemctl reset-failed "${DNSCRYPT_SERVICE}" \
        >/dev/null 2>&1 || true

    systemctl restart "${DNSCRYPT_SERVICE}"

    sleep 2

    if ! systemctl is-active --quiet "${DNSCRYPT_SERVICE}"; then
        systemctl status "${DNSCRYPT_SERVICE}" --no-pager || true
        journalctl -u "${DNSCRYPT_SERVICE}" -n 100 --no-pager || true

        die "dnscrypt-proxy service failed to start."
    fi

    REPORT_SERVICE="PASS"

    log_success "dnscrypt-proxy service is active."
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

wait_for_local_dns() {
    log_info "Waiting for local DNS listener..."

    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if ss -H -lntu 2>/dev/null |
            awk '$4 == "127.0.0.1:53" {found=1}
                 END {exit !found}'; then

            REPORT_LISTENER="PASS"

            log_success "DNS listener is active on 127.0.0.1:53."
            return 0
        fi

        log_debug "DNS listener is not ready; attempt ${attempt}/${MAX_RETRIES}"

        sleep "${RETRY_DELAY}"
        attempt=$((attempt + 1))
    done

    systemctl status "${DNSCRYPT_SERVICE}" --no-pager || true
    journalctl -u "${DNSCRYPT_SERVICE}" -n 100 --no-pager || true

    die "Local DNS listener did not start."
}

test_resolv_conf() {
    log_info "Checking /etc/resolv.conf..."

    if ! grep -Eq \
        '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1([[:space:]]*)$' \
        /etc/resolv.conf; then

        cat /etc/resolv.conf
        die "/etc/resolv.conf is not configured to use 127.0.0.1."
    fi

    REPORT_RESOLV="PASS"

    log_success "/etc/resolv.conf is correctly configured."
}

test_dns_udp() {
    log_info "Testing DNS over UDP..."

    if ! dig \
        +time=5 \
        +tries=2 \
        @"${DNS_ADDRESS}" \
        example.com \
        +short |
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then

        dig @"${DNS_ADDRESS}" example.com || true
        die "DNS over UDP test failed."
    fi

    REPORT_UDP="PASS"

    log_success "DNS over UDP test passed."
}

test_dns_tcp() {
    log_info "Testing DNS over TCP..."

    if ! dig \
        +tcp \
        +time=5 \
        +tries=2 \
        @"${DNS_ADDRESS}" \
        example.com \
        +short >/dev/null; then

        dig +tcp @"${DNS_ADDRESS}" example.com || true
        die "DNS over TCP test failed."
    fi

    REPORT_TCP="PASS"

    log_success "DNS over TCP test passed."
}

test_firewall_rules() {
    log_info "Checking firewall DNS blocking rules..."

    if ! iptables -S "${IPTABLES_CHAIN}" 2>/dev/null |
        grep -Eq -- '--dport (53|853).*DROP'; then

        die "IPv4 DNS blocking rules are missing."
    fi

    REPORT_IPV4_FIREWALL="PASS"

    if command -v ip6tables >/dev/null 2>&1 &&
        [[ -e /proc/net/if_inet6 ]]; then

        if ! ip6tables -S "${IP6TABLES_CHAIN}" 2>/dev/null |
            grep -Eq -- '--dport (53|853).*DROP'; then

            die "IPv6 DNS blocking rules are missing."
        fi

        REPORT_IPV6_FIREWALL="PASS"
    fi

    log_success "Direct outbound DNS blocking rules are active."
}

# ------------------------------------------------------------------------------
# Final Report
# ------------------------------------------------------------------------------

print_report_row() {
    local title="$1"
    local value="$2"

    printf '| %-32s | %-12s |\n' "${title}" "${value}"
}

show_final_report() {
    local version="unknown"
    local dns_result="FAILED"
    local ipv4_address="N/A"
    local ipv6_address="N/A"

    version="$("${DNSCRYPT_BINARY}" --version 2>/dev/null |
        head -n 1 || true)"

    [[ -n "${version}" ]] || version="dnscrypt-proxy"

    REPORT_DNSCRYPT_VERSION="${version}"

    if dig @"${DNS_ADDRESS}" example.com +short \
        >/tmp/dns-fix-dig-result 2>/dev/null &&
        [[ -s /tmp/dns-fix-dig-result ]]; then

        dns_result="$(head -n 1 /tmp/dns-fix-dig-result)"
    fi

    rm -f /tmp/dns-fix-dig-result

    ipv4_address="$(curl -4fsS --max-time 8 \
        https://api.ipify.org 2>/dev/null || echo "N/A")"

    ipv6_address="$(curl -6fsS --max-time 8 \
        https://api6.ipify.org 2>/dev/null || echo "N/A")"

    echo
    echo "======================================================================"
    echo "FINAL DNS LEAK PROTECTION REPORT"
    echo "======================================================================"

    printf '+----------------------------------+--------------+\n'
    printf '| %-32s | %-12s |\n' "Item" "Status"
    printf '+----------------------------------+--------------+\n'

    print_report_row "Operating system" "Ubuntu 22.04"
    print_report_row "dnscrypt-proxy" "${REPORT_DNSCRYPT_VERSION}"
    print_report_row "Service status" "${REPORT_SERVICE}"
    print_report_row "Local listener 127.0.0.1:53" "${REPORT_LISTENER}"
    print_report_row "/etc/resolv.conf" "${REPORT_RESOLV}"
    print_report_row "DNS over UDP" "${REPORT_UDP}"
    print_report_row "DNS over TCP" "${REPORT_TCP}"
    print_report_row "IPv4 DNS firewall" "${REPORT_IPV4_FIREWALL}"
    print_report_row "IPv6 DNS firewall" "${REPORT_IPV6_FIREWALL}"
    print_report_row "Persistent firewall rules" "${REPORT_PERSISTENCE}"
    print_report_row "DNS query example.com" "${dns_result}"
    print_report_row "Public IPv4" "${ipv4_address}"
    print_report_row "Public IPv6" "${ipv6_address}"

    printf '+----------------------------------+--------------+\n'

    echo
    echo "Configuration file:"
    echo "${DNSCRYPT_CONFIG}"

    echo
    echo "Firewall files:"
    echo "/etc/iptables/rules.v4"
    echo "/etc/iptables/rules.v6"

    echo
    echo "Backup directory:"
    echo "${BACKUP_DIR}"

    echo
    echo "Log file:"
    echo "${LOG_FILE}"

    echo
    echo "Notes:"
    echo "- DNS upstream is Cloudflare over DNS-over-HTTPS."
    echo "- Direct outbound DNS ports 53 and 853 are blocked."
    echo "- Applications with their own DoH, VPN or proxy may bypass this setup."
    echo "- Cloudflare Anycast does not guarantee the VPS country in leak tests."

    echo
    echo "======================================================================"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    require_root
    init_logging

    validate_os

    install_dependencies
    validate_commands

    backup_configuration

    remove_old_cloudflared
    disable_systemd_resolved
    disable_dnscrypt_socket

    create_dnscrypt_user
    configure_dnscrypt_proxy
    create_dnscrypt_service

    configure_resolv_conf

    # Start dnscrypt-proxy before applying firewall rules.
    # This allows initial resolver discovery/bootstrap.
    start_dnscrypt_service
    wait_for_local_dns

    configure_firewall

    test_resolv_conf
    test_dns_udp
    test_dns_tcp
    test_firewall_rules

    show_final_report

    log_success "DNS leak protection configuration completed successfully."
}

main "$@"
