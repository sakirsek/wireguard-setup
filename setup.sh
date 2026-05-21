#!/usr/bin/env bash
#
# WireGuard VPN server setup for Ubuntu VPS.
# Run once on a fresh server to turn it into a WireGuard endpoint.
#
# Usage: sudo ./setup.sh [options]
# Run with --help for the full option list.

set -euo pipefail

# ---------- Defaults (override via CLI flags) ----------
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_SUBNET="10.66.66.0/24"
WG_IPV6_SUBNET="fd42:42:42::/64"
WG_DNS="1.1.1.1, 1.0.0.1"
USE_IPV6=false
USE_PSK=false
INITIAL_CLIENT="client"
NO_CLIENT=false
ENDPOINT_OVERRIDE=""
FORCE=false

# ---------- Paths ----------
WG_DIR="/etc/wireguard"
SERVER_CONF=""           # set after parsing flags
SERVER_ENV="$WG_DIR/server.env"
CLIENTS_DIR="$WG_DIR/clients"

# ---------- Colors / logging ----------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'
    C_BLU='\033[0;34m'; C_DIM='\033[2m';    C_RST='\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_RST=''
fi
log()  { printf "${C_BLU}[INFO]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YLW}[WARN]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERROR]${C_RST} %s\n" "$*" >&2; }
ok()   { printf "${C_GRN}[OK]${C_RST}    %s\n" "$*"; }

usage() {
    cat <<EOF
WireGuard VPN server setup script

Usage: sudo $0 [options]

Options:
  --port <n>           UDP port (default: $WG_PORT)
  --subnet <cidr>      IPv4 subnet, /24 only (default: $WG_SUBNET)
  --dns <list>         DNS servers, comma-separated (default: $WG_DNS)
  --endpoint <host>    Public endpoint hostname/IP (default: auto-detect)
  --ipv6               Enable IPv6 dual-stack
  --with-psk           Enable pre-shared keys for added symmetric security
  --client <name>      Initial client name (default: $INITIAL_CLIENT)
  --no-client          Skip initial client creation
  --force              Overwrite existing server config without prompting
  -h, --help           Show this help

Examples:
  sudo $0
  sudo $0 --port 51820 --client laptop --ipv6
  sudo $0 --endpoint vpn.example.com --no-client

After setup:
  - Allow UDP \$port inbound on your cloud provider firewall
  - Add more clients with: sudo ./add-client.sh <name>
  - Remove clients with:   sudo ./remove-client.sh <name>
EOF
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      WG_PORT="$2";           shift 2 ;;
        --subnet)    WG_SUBNET="$2";         shift 2 ;;
        --dns)       WG_DNS="$2";            shift 2 ;;
        --endpoint)  ENDPOINT_OVERRIDE="$2"; shift 2 ;;
        --ipv6)      USE_IPV6=true;          shift ;;
        --with-psk)  USE_PSK=true;           shift ;;
        --client)    INITIAL_CLIENT="$2";    shift 2 ;;
        --no-client) NO_CLIENT=true;         shift ;;
        --force)     FORCE=true;             shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           err "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
done

SERVER_CONF="$WG_DIR/${WG_INTERFACE}.conf"

# Derive server IP and prefix from subnet (assumes /24)
SUBNET_BASE="${WG_SUBNET%.*}"
SUBNET_PREFIX="${WG_SUBNET##*/}"
WG_SERVER_IP="${SUBNET_BASE}.1"
WG_IPV6_BASE="${WG_IPV6_SUBNET%::/*}"
WG_IPV6_SERVER="${WG_IPV6_BASE}::1"

# ---------- Preflight ----------

if [[ $EUID -ne 0 ]]; then
    err "Root privileges required. Run as: sudo $0"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    err "Cannot read /etc/os-release; distro detection failed."
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is designed for Ubuntu (detected: ${ID:-unknown}). Continuing, but untested."
fi

if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
    err "Invalid port: $WG_PORT"
    exit 1
fi

if ! [[ "$WG_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.0/24$ ]]; then
    err "Only /24 IPv4 subnets are currently supported: $WG_SUBNET"
    exit 1
fi

# ---------- Detect WAN interface ----------
NETWORK_INTERFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
if [[ -z "$NETWORK_INTERFACE" ]]; then
    err "Default network interface not found."
    exit 1
fi
log "WAN interface: $NETWORK_INTERFACE"

# ---------- Detect public IP ----------
detect_public_ip() {
    if [[ -n "$ENDPOINT_OVERRIDE" ]]; then
        printf '%s' "$ENDPOINT_OVERRIDE"
        return 0
    fi
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ipv4.icanhazip.com"; do
        ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

if ! PUBLIC_ENDPOINT="$(detect_public_ip)"; then
    err "Could not detect public IP. Provide one manually with --endpoint <ip-or-host>."
    exit 1
fi
log "Public endpoint: $PUBLIC_ENDPOINT"

# ---------- Install packages ----------
log "Installing packages (wireguard, qrencode, iptables, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    wireguard wireguard-tools \
    qrencode iptables curl ca-certificates iproute2 >/dev/null
ok "Packages installed"

# ---------- Existing server config check ----------
if [[ -f "$SERVER_CONF" && "$FORCE" != true ]]; then
    err "$SERVER_CONF already exists. Use --force to overwrite, or remove it first."
    exit 1
fi

# ---------- Generate server keys (idempotent) ----------
install -d -m 700 "$WG_DIR" "$CLIENTS_DIR"
umask 077

if [[ ! -s "$WG_DIR/server_private.key" ]]; then
    wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key" "$WG_DIR/server_public.key"
    ok "Server keys generated"
else
    warn "Using existing server keys at $WG_DIR/server_private.key"
fi
SERVER_PRIVATE_KEY="$(cat "$WG_DIR/server_private.key")"
SERVER_PUBLIC_KEY="$(cat "$WG_DIR/server_public.key")"

# ---------- Backup existing server.conf if --force ----------
if [[ -f "$SERVER_CONF" ]]; then
    backup="$SERVER_CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$SERVER_CONF" "$backup"
    warn "Existing config backed up to $backup"
fi

# ---------- Build PostUp/PostDown rules ----------
# Match-on-interface masquerade is cleaner than match-on-WAN — it survives
# WAN interface renames and is the canonical wg-quick pattern.
POSTUP="iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE"
POSTDOWN="iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE"

ADDR_LINE="${WG_SERVER_IP}/${SUBNET_PREFIX}"
if [[ "$USE_IPV6" == true ]]; then
    ADDR_LINE="${ADDR_LINE}, ${WG_IPV6_SERVER}/64"
    POSTUP="${POSTUP}; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE"
    POSTDOWN="${POSTDOWN}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE"
fi

# ---------- Write server.conf ----------
cat > "$SERVER_CONF" <<EOF
# WireGuard server config — managed by setup.sh
# Peers are appended by add-client.sh / remove-client.sh.
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address    = $ADDR_LINE
ListenPort = $WG_PORT
PostUp     = $POSTUP
PostDown   = $POSTDOWN
EOF
chmod 600 "$SERVER_CONF"
ok "Server config written: $SERVER_CONF"

# ---------- IP forwarding (drop-in sysctl) ----------
{
    echo "net.ipv4.ip_forward = 1"
    [[ "$USE_IPV6" == true ]] && echo "net.ipv6.conf.all.forwarding = 1"
} > /etc/sysctl.d/99-wireguard.conf
sysctl -q --system >/dev/null
ok "IP forwarding enabled"

# ---------- Save server.env for client helpers ----------
cat > "$SERVER_ENV" <<EOF
# Generated by setup.sh — read by add-client.sh / remove-client.sh.
WG_INTERFACE="$WG_INTERFACE"
WG_PORT="$WG_PORT"
WG_SUBNET="$WG_SUBNET"
WG_SERVER_IP="$WG_SERVER_IP"
WG_DNS="$WG_DNS"
WG_IPV6_SUBNET="$WG_IPV6_SUBNET"
SERVER_PUBLIC_KEY="$SERVER_PUBLIC_KEY"
SERVER_PUBLIC_ENDPOINT="$PUBLIC_ENDPOINT"
USE_IPV6=$USE_IPV6
USE_PSK=$USE_PSK
EOF
chmod 600 "$SERVER_ENV"

# ---------- Start service ----------
log "Starting WireGuard service..."
systemctl enable -q "wg-quick@${WG_INTERFACE}"
systemctl restart "wg-quick@${WG_INTERFACE}"
if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    err "wg-quick@${WG_INTERFACE} failed to start. Check 'journalctl -u wg-quick@${WG_INTERFACE}'."
    exit 1
fi
ok "wg-quick@${WG_INTERFACE} is active"

# ---------- Create initial client ----------
if [[ "$NO_CLIENT" != true ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$SCRIPT_DIR/add-client.sh" ]]; then
        echo
        log "Creating initial client: $INITIAL_CLIENT"
        "$SCRIPT_DIR/add-client.sh" "$INITIAL_CLIENT"
    else
        warn "add-client.sh not found or not executable — initial client skipped."
        warn "Add one manually: sudo ./add-client.sh <name>"
    fi
fi

# ---------- Done ----------
cat <<EOF

$(printf "${C_GRN}========================================${C_RST}")
$(printf "${C_GRN} Setup complete${C_RST}")
$(printf "${C_GRN}========================================${C_RST}")

$(printf "${C_DIM}Next steps:${C_RST}")
  - Open UDP ${WG_PORT} on your cloud provider firewall (security group / firewall rules)
  - Add a client:     ${C_BLU}sudo ./add-client.sh <name>${C_RST}
  - Remove a client:  ${C_BLU}sudo ./remove-client.sh <name>${C_RST}
  - Service status:   ${C_BLU}systemctl status wg-quick@${WG_INTERFACE}${C_RST}
  - Active peers:     ${C_BLU}sudo wg show${C_RST}

EOF
