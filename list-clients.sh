#!/usr/bin/env bash
#
# List WireGuard clients with their friendly names alongside live state.
# `wg show` only knows public keys, so this joins the BEGIN/END markers
# from wg0.conf (written by add-client.sh) with `wg show <iface> dump`.
#
# Usage:
#   sudo ./list-clients.sh           # table of all clients
#   sudo ./list-clients.sh <name>    # print that client's config + QR code

set -euo pipefail

WG_DIR="/etc/wireguard"
SERVER_ENV="$WG_DIR/server.env"
CLIENTS_DIR="$WG_DIR/clients"

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'
    C_BLU='\033[0;34m'; C_DIM='\033[2m';    C_BLD='\033[1m'; C_RST='\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_BLD=''; C_RST=''
fi
err()  { printf "${C_RED}[ERROR]${C_RST} %s\n" "$*" >&2; }
warn() { printf "${C_YLW}[WARN]${C_RST}  %s\n" "$*"; }

# ---------- Preflight ----------
if [[ $EUID -ne 0 ]]; then
    err "Root privileges required: sudo $0 [<client-name>]"
    exit 1
fi

if [[ ! -f "$SERVER_ENV" ]]; then
    err "$SERVER_ENV not found. Run ./setup.sh first."
    exit 1
fi
# shellcheck disable=SC1090
. "$SERVER_ENV"

SERVER_CONF="$WG_DIR/${WG_INTERFACE}.conf"
if [[ ! -f "$SERVER_CONF" ]]; then
    err "$SERVER_CONF not found."
    exit 1
fi

# ---------- Single-client mode ----------
if [[ $# -ge 1 ]]; then
    CLIENT_NAME="$1"
    if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
        err "Invalid client name: '$CLIENT_NAME'"
        exit 1
    fi
    CLIENT_CONF="$CLIENTS_DIR/${CLIENT_NAME}.conf"
    if [[ ! -f "$CLIENT_CONF" ]]; then
        err "Client '$CLIENT_NAME' not found: $CLIENT_CONF"
        err "Available clients:"
        ls -1 "$CLIENTS_DIR" 2>/dev/null | sed 's/\.conf$//' | sed 's/^/  - /' >&2 || echo "  (none)" >&2
        exit 1
    fi

    printf "${C_DIM}─── %s ───${C_RST}\n" "$CLIENT_CONF"
    cat "$CLIENT_CONF"
    printf "${C_DIM}─────────────────────────────────────────${C_RST}\n"
    if command -v qrencode >/dev/null 2>&1; then
        echo
        qrencode -t ansiutf8 < "$CLIENT_CONF"
    fi
    exit 0
fi

# ---------- Table mode ----------

# Build pubkey → name map from server config
declare -A name_by_key
current=""
while IFS= read -r line; do
    if [[ "$line" =~ ^"# BEGIN client: "([A-Za-z0-9_-]+) ]]; then
        current="${BASH_REMATCH[1]}"
    elif [[ -n "$current" && "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        key="${key// /}"
        name_by_key["$key"]="$current"
        current=""
    fi
done < "$SERVER_CONF"

# Helper: human-friendly duration since epoch
fmt_handshake() {
    local epoch="$1"
    if [[ -z "$epoch" || "$epoch" == "0" ]]; then
        echo "never"
        return
    fi
    local now delta
    now=$(date +%s)
    delta=$(( now - epoch ))
    if   (( delta < 60 ));     then echo "${delta}s ago"
    elif (( delta < 3600 ));   then echo "$((delta / 60))m ago"
    elif (( delta < 86400 ));  then echo "$((delta / 3600))h ago"
    else                            echo "$((delta / 86400))d ago"
    fi
}

fmt_bytes() {
    local n="${1:-0}"
    [[ "$n" == "0" || -z "$n" ]] && { echo "0B"; return; }
    numfmt --to=iec --suffix=B "$n" 2>/dev/null || echo "${n}B"
}

# Check interface is up
if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    warn "wg-quick@${WG_INTERFACE} is not running. Listing peers from config only."
    echo
    printf "${C_BLD}%-20s  %-15s${C_RST}\n" "NAME" "IPv4"
    printf "%-20s  %-15s\n" "--------------------" "---------------"
    current=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^"# BEGIN client: "([A-Za-z0-9_-]+) ]]; then
            current="${BASH_REMATCH[1]}"
        elif [[ -n "$current" && "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            ips="${BASH_REMATCH[1]}"
            ipv4="${ips%%,*}"
            ipv4="${ipv4%/*}"
            printf "%-20s  %-15s\n" "$current" "$ipv4"
            current=""
        fi
    done < "$SERVER_CONF"
    exit 0
fi

# Live mode — pull dump and join with names
printf "${C_BLD}interface: %s${C_RST}  ${C_DIM}(endpoint: %s:%s, server key: %s)${C_RST}\n\n" \
    "$WG_INTERFACE" "$SERVER_PUBLIC_ENDPOINT" "$WG_PORT" "${SERVER_PUBLIC_KEY:0:12}..."

printf "${C_BLD}%-20s  %-15s  %-15s  %s${C_RST}\n" "NAME" "IPv4" "HANDSHAKE" "TRANSFER (rx/tx)"
printf "%-20s  %-15s  %-15s  %s\n" \
    "--------------------" "---------------" "---------------" "--------------------"

count=0
while IFS=$'\t' read -r pub _psk _endpoint allowed handshake rx tx _ka; do
    [[ -z "$pub" ]] && continue
    name="${name_by_key[$pub]:-${C_DIM}(unknown)${C_RST}}"
    ipv4="${allowed%%,*}"
    ipv4="${ipv4%/*}"
    hs=$(fmt_handshake "$handshake")
    rx_h=$(fmt_bytes "$rx")
    tx_h=$(fmt_bytes "$tx")
    printf "%-20s  %-15s  %-15s  %s / %s\n" "$name" "$ipv4" "$hs" "$rx_h" "$tx_h"
    count=$((count + 1))
done < <(wg show "$WG_INTERFACE" dump | tail -n +2)

if (( count == 0 )); then
    printf "${C_DIM}(no peers configured — add one with: sudo ./add-client.sh <name>)${C_RST}\n"
fi

echo
printf "${C_DIM}Tip: 'sudo %s <name>' to print a single client's config + QR.${C_RST}\n" "$(basename "$0")"
