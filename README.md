# wireguard-setup

Turn a fresh Ubuntu VPS into a WireGuard VPN endpoint with a single command, then manage peers with two small helper scripts.

## What it does

- Installs WireGuard and related tools
- Generates server keys and writes `/etc/wireguard/wg0.conf`
- Enables IP forwarding persistently via a drop-in sysctl file
- Wires `iptables` NAT / forward rules into wg-quick `PostUp` / `PostDown` — applied on service start, cleaned up on service stop
- Enables and starts the systemd unit
- Creates an initial client, writes its config to disk, prints a **terminal QR code** for mobile import, and dumps the raw config text for copy-paste on desktop
- Lets you add / list / remove peers later with `add-client.sh` / `list-clients.sh` / `remove-client.sh`, applied live without dropping existing connections

## Quick start

On a fresh Ubuntu 22.04 / 24.04 VPS:

```bash
git clone https://github.com/sakirsek/wireguard-setup.git
cd wireguard-setup
chmod +x setup.sh add-client.sh remove-client.sh
sudo ./setup.sh
```

That's it. The script:
- Asks no questions and runs with sane defaults
- Creates a peer named `client`
- Prints the config file path and a QR code

You still need to allow **UDP 51820** in your cloud provider's firewall — see [Cloud firewall](#cloud-firewall) below.

## Defaults

| Setting | Value | Override |
|---|---|---|
| UDP port | `51820` | `--port` |
| Subnet | `10.66.66.0/24` | `--subnet` |
| DNS | `1.1.1.1, 1.0.0.1` (Cloudflare) | `--dns` |
| Public endpoint | auto-detect (3-service fallback) | `--endpoint` |
| IPv6 | off | `--ipv6` |
| Pre-shared key | off | `--with-psk` |
| Initial client name | `client` | `--client <name>` |

Run `sudo ./setup.sh --help` for the full flag list.

## Examples

```bash
# Standard install
sudo ./setup.sh

# Custom port, IPv6 dual-stack, named initial client
sudo ./setup.sh --port 41820 --ipv6 --client laptop

# Auto-detection failing? Pin the endpoint manually
sudo ./setup.sh --endpoint vpn.example.com

# Extra symmetric layer (post-quantum hedge)
sudo ./setup.sh --with-psk

# Set up the server but add clients later
sudo ./setup.sh --no-client
sudo ./add-client.sh phone
```

## Managing clients

```bash
# Add a peer (applied live; existing peers stay connected)
sudo ./add-client.sh phone
sudo ./add-client.sh laptop

# List all peers with their names, IPs, last handshake, transfer
sudo ./list-clients.sh

# Print one client's config + QR code (for re-importing later)
sudo ./list-clients.sh phone

# Remove a peer
sudo ./remove-client.sh phone
```

`wg show` only knows public keys; `list-clients.sh` joins them with the friendly names stored in the server config and emits a readable table:

```
interface: wg0  (endpoint: 1.2.3.4:51820, server key: PIfCI5Bzpd9...)

NAME                  IPv4             HANDSHAKE        TRANSFER (rx/tx)
--------------------  ---------------  ---------------  --------------------
client                10.66.66.2       2m ago           12.3MB / 4.1MB
phone                 10.66.66.3       never            0B / 0B
laptop                10.66.66.4       1h ago           456MB / 89MB
```

Each `add-client.sh` run:
1. Writes `/etc/wireguard/clients/<name>.conf` (mode `600`)
2. Prints an ANSI QR code for the mobile WireGuard app
3. Dumps the raw config text to the terminal — copy-paste straight into your desktop client, no `scp` needed
4. Reloads the interface with `wg syncconf`, so other peers stay connected

If you want the file on disk, `scp` it directly:

```bash
scp <user>@<server>:/etc/wireguard/clients/<name>.conf .
```

## Cloud firewall

The scripts handle local `iptables` rules automatically, but your cloud provider's perimeter firewall is a separate layer that you have to open yourself:

- **Protocol:** UDP
- **Port:** `51820` (or whatever you passed to `--port`)
- **Source:** `0.0.0.0/0` (or restrict to specific source ranges if you prefer)

Provider-specific notes:

- **AWS EC2** — Security Group → Inbound rules → Custom UDP, port 51820, 0.0.0.0/0
- **DigitalOcean** — Networking → Firewalls → Inbound rules → UDP 51820
- **Hetzner Cloud** — Cloud Console → Firewalls → Inbound rules → UDP 51820
- **Vultr / Linode** — same idea via their respective firewall UIs

## Troubleshooting

| Symptom | What to check |
|---|---|
| Service won't start | `journalctl -u wg-quick@wg0 -n 50` |
| `wg show` is empty | `systemctl status wg-quick@wg0`, then restart |
| Client connects but has no internet | Confirm UDP port is open in the cloud firewall; verify `sysctl net.ipv4.ip_forward` returns `1` |
| Wrong public IP detected | `sudo ./setup.sh --endpoint <correct-ip-or-host> --force` |
| Want to rotate a client's keys | `sudo ./remove-client.sh <name> && sudo ./add-client.sh <name>` |

## File layout

```
/etc/wireguard/
├── wg0.conf                # Server config — peers are appended here
├── server.env              # State file consumed by the helper scripts
├── server_private.key      # mode 600, root
├── server_public.key
└── clients/
    ├── client.conf         # mode 600, root
    ├── laptop.conf
    └── phone.conf
```

## Security notes

- All private keys are `chmod 600` under `/etc/wireguard/` (`chmod 700`)
- Public IP detection falls back across three independent services (`api.ipify.org` → `ifconfig.me` → `icanhazip.com`); pinning with `--endpoint` is still recommended once you know the real address
- The **SOCKS5 proxy that earlier versions of this script set up has been removed.** It was an unauthenticated open proxy bound to `0.0.0.0`, which is a well-known abuse vector (botnet / spam exit nodes). WireGuard already provides a full tunnel, so the proxy added attack surface with no real benefit
- PSK support is optional and off by default. Modern WireGuard's Curve25519 handshake is strong on its own; `--with-psk` adds a symmetric layer that some operators want as a post-quantum hedge

## Requirements

- Ubuntu 22.04 / 24.04 LTS (tested; Debian likely works but isn't verified)
- Root access
- UDP 51820 open in the cloud provider firewall

## License

[MIT](LICENSE)
