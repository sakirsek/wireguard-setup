#!/bin/bash

set -e  # Stop the script if any command fails

# Variables
WG_INTERFACE="wg0"
SERVER_IP="10.0.0.1/24"
CLIENT_IP="10.0.0.2/32"
WG_PORT=51820
SOCKS_PORT=1080
SERVER_CONFIG="/etc/wireguard/wg0.conf"

# Automatically detect the network interface
NETWORK_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$NETWORK_INTERFACE" ]; then
    echo "❌ Network interface not detected! Please set it manually."
    exit 1
fi

echo "🚀 Starting WireGuard Setup on AWS EC2..."

# 📝 Install Required Packages
echo "📝 Installing required dependencies..."
sudo apt update && sudo apt install -y wireguard iptables-persistent curl unzip net-tools dante-server

# 🔐 Create WireGuard Directory and Keys
echo "🔐 Generating required keys for WireGuard..."
sudo mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077  # Tighten security permissions

# 🔑 Generate Server Keys
wg genkey | tee privatekey | wg pubkey > publickey
SERVER_PRIVATE_KEY=$(cat privatekey)
SERVER_PUBLIC_KEY=$(cat publickey)

# 🔑 Generate Client Keys
wg genkey | tee client_privatekey | wg pubkey > client_publickey
CLIENT_PRIVATE_KEY=$(cat client_privatekey)
CLIENT_PUBLIC_KEY=$(cat client_publickey)

# 🔧 Create WireGuard Configuration File (Server)
echo "🔧 Creating WireGuard server configuration file..."
sudo bash -c "cat > $SERVER_CONFIG" <<EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_IP
ListenPort = $WG_PORT
SaveConfig = false
PostUp = iptables -A FORWARD -i $WG_INTERFACE -o $NETWORK_INTERFACE -j ACCEPT; iptables -A FORWARD -i $NETWORK_INTERFACE -o $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -o $NETWORK_INTERFACE -j ACCEPT; iptables -D FORWARD -i $NETWORK_INTERFACE -o $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP
PersistentKeepalive = 25
EOF

# 🌐 Enable IP Forwarding
echo "🌐 Enabling IP forwarding..."
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 🛡️ Configure Firewall and IPTables Rules
echo "🛡️ Adding firewall rules..."
sudo iptables -A INPUT -p udp --dport $WG_PORT -j ACCEPT
sudo iptables -A FORWARD -i $WG_INTERFACE -o $NETWORK_INTERFACE -j ACCEPT
sudo iptables -A FORWARD -i $NETWORK_INTERFACE -o $WG_INTERFACE -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE
sudo netfilter-persistent save

# 🚀 Start and Enable WireGuard Service
echo "🚀 Starting WireGuard..."
sudo systemctl enable wg-quick@$WG_INTERFACE
sudo systemctl start wg-quick@$WG_INTERFACE

# 🔧 Configure SOCKS Proxy (Dante)
echo "🔧 Configuring SOCKS proxy with Dante..."
sudo bash -c "cat > /etc/danted.conf" <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
internal: 0.0.0.0 port = $SOCKS_PORT
external: $NETWORK_INTERFACE
socksmethod: username none
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
EOF

sudo systemctl restart danted
sudo systemctl enable danted

# 🔐 Display Client Configuration in Terminal
echo ""
echo "✅ WireGuard setup completed!"
echo "🔑 Copy the following configuration and use it in your WireGuard client:"
echo "----------------------------------------------------"
echo "[Interface]"
echo "PrivateKey = $CLIENT_PRIVATE_KEY"
echo "Address = $CLIENT_IP"
echo "DNS = 8.8.8.8"
echo ""
echo "[Peer]"
echo "PublicKey = $SERVER_PUBLIC_KEY"
echo "Endpoint = $(curl -s ifconfig.me):$WG_PORT"
echo "AllowedIPs = 0.0.0.0/0"
echo "PersistentKeepalive = 25"
echo "----------------------------------------------------"
echo ""
echo "📅 Save this configuration as a .conf file and import it into your WireGuard client."
