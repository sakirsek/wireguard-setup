#!/usr/bin/env bash
#
# Add a WireGuard client (peer) to an already-configured server.
# Generates keys, allocates the next free IP, appends [Peer] to wg0.conf,
# and reloads the interface without dropping existing peers.
#
# Usage: sudo ./add-client.sh <client-name>

set -euo pipefail

WG_DIR="/etc/wireguard"
SERVER_ENV="$WG_DIR/server.env"
CLIENTS_DIR="$WG_DIR/clients"

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
Usage: sudo $0 <client-name>

Add a new WireGuard peer. <client-name> must match [a-zA-Z0-9_-] (1-32 chars).
Output: $CLIENTS_DIR/<client-name>.conf + an ANSI QR code on the terminal.
EOF
}

# ---------- Preflight ----------

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
    err "Invalid client name: '$CLIENT_NAME' — allowed: a-z A-Z 0-9 _ - (max 32 chars)"
    exit 1
fi

if [[ ! -f "$SERVER_ENV" ]]; then
    err "$SERVER_ENV not found. Run ./setup.sh first."
    exit 1
fi

# shellcheck disable=SC1090
. "$SERVER_ENV"

SERVER_CONF="$WG_DIR/${WG_INTERFACE}.conf"
CLIENT_CONF="$CLIENTS_DIR/${CLIENT_NAME}.conf"

if [[ ! -f "$SERVER_CONF" ]]; then
    err "$SERVER_CONF not found. Did setup.sh complete successfully?"
    exit 1
fi

if [[ -f "$CLIENT_CONF" ]]; then
    err "Client '$CLIENT_NAME' already exists: $CLIENT_CONF"
    err "Remove it first: sudo ./remove-client.sh $CLIENT_NAME"
    exit 1
fi

for tool in wg qrencode; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        err "Required command not found: $tool"
        exit 1
    fi
done

# ---------- Allocate next free IPv4 ----------

SUBNET_BASE="${WG_SUBNET%.*}"
SUBNET_PREFIX="${WG_SUBNET##*/}"

# Collect IPs already used by server + peers in this subnet
USED_IPS="$(grep -oE "${SUBNET_BASE}\.[0-9]+" "$SERVER_CONF" | sort -u || true)"

CLIENT_INDEX=""
CLIENT_IPV4=""
for i in $(seq 2 254); do
    candidate="${SUBNET_BASE}.${i}"
    if ! grep -qx "$candidate" <<<"$USED_IPS"; then
        CLIENT_IPV4="$candidate"
        CLIENT_INDEX="$i"
        break
    fi
done

if [[ -z "$CLIENT_IPV4" ]]; then
    err "Subnet ${WG_SUBNET} is full — no free IPs left."
    exit 1
fi

CLIENT_IPV6=""
if [[ "${USE_IPV6:-false}" == "true" ]]; then
    IPV6_BASE="${WG_IPV6_SUBNET%::/*}"
    CLIENT_IPV6="${IPV6_BASE}::$(printf '%x' "$CLIENT_INDEX")"
fi

log "Assigned IP: $CLIENT_IPV4${CLIENT_IPV6:+, $CLIENT_IPV6}"

# ---------- Generate keys (and PSK if enabled) ----------
umask 077
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

wg genkey | tee "$TMPDIR/priv" | wg pubkey > "$TMPDIR/pub"
CLIENT_PRIVATE_KEY="$(cat "$TMPDIR/priv")"
CLIENT_PUBLIC_KEY="$(cat "$TMPDIR/pub")"

PSK=""
if [[ "${USE_PSK:-false}" == "true" ]]; then
    PSK="$(wg genpsk)"
fi

# ---------- Build addresses & allowed-ips ----------
CLIENT_ADDR="${CLIENT_IPV4}/32"
PEER_ALLOWED="${CLIENT_IPV4}/32"
CLIENT_ALLOWED="0.0.0.0/0"
if [[ -n "$CLIENT_IPV6" ]]; then
    CLIENT_ADDR="${CLIENT_ADDR}, ${CLIENT_IPV6}/128"
    PEER_ALLOWED="${PEER_ALLOWED}, ${CLIENT_IPV6}/128"
    CLIENT_ALLOWED="0.0.0.0/0, ::/0"
fi

# ---------- Write client config ----------
{
    echo "[Interface]"
    echo "PrivateKey = $CLIENT_PRIVATE_KEY"
    echo "Address    = $CLIENT_ADDR"
    echo "DNS        = $WG_DNS"
    echo
    echo "[Peer]"
    echo "PublicKey  = $SERVER_PUBLIC_KEY"
    [[ -n "$PSK" ]] && echo "PresharedKey = $PSK"
    echo "Endpoint   = ${SERVER_PUBLIC_ENDPOINT}:${WG_PORT}"
    echo "AllowedIPs = $CLIENT_ALLOWED"
    echo "PersistentKeepalive = 25"
} > "$CLIENT_CONF"
chmod 600 "$CLIENT_CONF"

# ---------- Append peer to server config ----------
{
    echo
    echo "# BEGIN client: ${CLIENT_NAME} — added $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[Peer]"
    echo "PublicKey  = $CLIENT_PUBLIC_KEY"
    [[ -n "$PSK" ]] && echo "PresharedKey = $PSK"
    echo "AllowedIPs = $PEER_ALLOWED"
    echo "# END client: ${CLIENT_NAME}"
} >> "$SERVER_CONF"

# ---------- Apply live without dropping the interface ----------
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    ok "Peer applied live (existing connections preserved)"
else
    warn "wg-quick@${WG_INTERFACE} is not running. Start it with: sudo systemctl start wg-quick@${WG_INTERFACE}"
fi

# ---------- Output ----------
echo
ok "Client '${CLIENT_NAME}' added"
echo "  Config:      ${CLIENT_CONF}"
echo "  Assigned IP: ${CLIENT_IPV4}${CLIENT_IPV6:+, $CLIENT_IPV6}"
echo
echo "QR code (scan with the WireGuard mobile app):"
echo
qrencode -t ansiutf8 < "$CLIENT_CONF"
echo
printf "${C_DIM}─── config (copy into your WireGuard client) ───${C_RST}\n"
cat "$CLIENT_CONF"
printf "${C_DIM}────────────────────────────────────────────────${C_RST}\n"
echo
printf "${C_DIM}Or download the file:${C_RST}\n"
printf "  scp <user>@%s:%s .\n" "$SERVER_PUBLIC_ENDPOINT" "$CLIENT_CONF"
echo
