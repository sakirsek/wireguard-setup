#!/usr/bin/env bash
#
# Remove a WireGuard client (peer) by name.
# Deletes the [Peer] block from the server config (delimited by the
# BEGIN/END markers add-client.sh writes), deletes the client config,
# and reloads the interface without dropping other peers.
#
# Usage: sudo ./remove-client.sh <client-name>

set -euo pipefail

WG_DIR="/etc/wireguard"
SERVER_ENV="$WG_DIR/server.env"
CLIENTS_DIR="$WG_DIR/clients"

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'
    C_BLU='\033[0;34m'; C_RST='\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi
log()  { printf "${C_BLU}[INFO]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YLW}[WARN]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERROR]${C_RST} %s\n" "$*" >&2; }
ok()   { printf "${C_GRN}[OK]${C_RST}    %s\n" "$*"; }

usage() { echo "Usage: sudo $0 <client-name>"; }

if [[ $EUID -ne 0 ]]; then
    err "Root privileges required: sudo $0 <client-name>"
    exit 1
fi

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit "$([[ $# -lt 1 ]] && echo 1 || echo 0)"
fi

CLIENT_NAME="$1"
if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
    err "Invalid client name: '$CLIENT_NAME'"
    exit 1
fi

if [[ ! -f "$SERVER_ENV" ]]; then
    err "$SERVER_ENV not found. setup.sh has not been run."
    exit 1
fi
# shellcheck disable=SC1090
. "$SERVER_ENV"

SERVER_CONF="$WG_DIR/${WG_INTERFACE}.conf"
CLIENT_CONF="$CLIENTS_DIR/${CLIENT_NAME}.conf"

if [[ ! -f "$SERVER_CONF" ]]; then
    err "$SERVER_CONF not found."
    exit 1
fi

# Check whether the marker exists in the server config
if ! grep -qF "# BEGIN client: ${CLIENT_NAME}" "$SERVER_CONF"; then
    err "No peer named '${CLIENT_NAME}' in the server config."
    err "Existing clients:"
    grep -oE '# BEGIN client: [^ ]+' "$SERVER_CONF" | sed 's/# BEGIN client: /  - /' >&2 || echo "  (none)" >&2
    exit 1
fi

# Backup before modifying
backup="$SERVER_CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$SERVER_CONF" "$backup"
log "Backup: $backup"

# Delete the block between markers (inclusive). Name is validated to
# [a-zA-Z0-9_-] so no regex-escape needed. The "(space|end)" boundary
# prevents "laptop" from matching "laptop2".
tmp="$(mktemp)"
awk -v name="$CLIENT_NAME" '
    BEGIN { skip = 0; begin = "^# BEGIN client: " name "([[:space:]]|$)" }
    $0 ~ begin                          { skip = 1; next }
    skip && $0 == "# END client: " name { skip = 0; next }
    !skip                               { print }
' "$SERVER_CONF" > "$tmp"

# Sanity check: marker should be gone
if grep -qF "# BEGIN client: ${CLIENT_NAME}" "$tmp"; then
    err "Failed to remove the peer block (unexpected awk state). Backup kept: $backup"
    rm -f "$tmp"
    exit 1
fi

# Drop trailing blank lines and write back
sed -e :a -e '/^$/{$d;N;ba' -e '}' "$tmp" > "$SERVER_CONF"
chmod 600 "$SERVER_CONF"
rm -f "$tmp"

# Remove client config file
if [[ -f "$CLIENT_CONF" ]]; then
    rm -f "$CLIENT_CONF"
    log "Client config removed: $CLIENT_CONF"
else
    warn "Client config file did not exist: $CLIENT_CONF"
fi

# Apply live
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    ok "Peer removed live: ${CLIENT_NAME}"
else
    warn "wg-quick@${WG_INTERFACE} is not running; removed from config only."
fi
