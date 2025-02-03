# WireGuard EC2 Setup Script

🚀 **Automated WireGuard VPN setup script for AWS EC2.**  
This script installs, configures, and enables WireGuard VPN on an AWS EC2 instance with automatic firewall and network settings.

## 📌 Features
- 🔹 Installs WireGuard and required dependencies
- 🔹 Automatically detects network interface
- 🔹 Configures IP forwarding and firewall rules
- 🔹 Generates secure keys for the server and client
- 🔹 Provides a ready-to-use WireGuard client configuration
- 🔹 Outputs the WireGuard configuration file in the terminal for easy copying and usage

## 🛠️ Installation & Usage

1. **Clone the repository**:
   ```bash
   git clone https://github.com/sakirsek/wireguard-setup.git
   cd wireguard-setup
   ```

2. **Make the script executable**:
   ```bash
   chmod +x setup.sh
   ```

3. **Run the script**:
   ```bash
   sudo ./setup.sh
   ```

4. **Open the WireGuard port on AWS EC2 Security Group**:
   - Go to **AWS Management Console** → **EC2** → **Security Groups**.
   - Find the security group associated with your EC2 instance.
   - Add an **inbound rule** to allow **UDP traffic on port 51820** (or the port you configured in the script).
   - Set the source as **0.0.0.0/0** (or restrict it to your specific IPs).

5. **Copy and use the client configuration**:
   - The script will generate a WireGuard configuration for the client and display it in the terminal.
   - Copy the configuration output and save it as `client.conf`.
   - Import `client.conf` into your WireGuard client to establish a connection.

## 📄 License
This project is licensed under the [MIT License](LICENSE).

## 🤝 Contributing
Pull requests are welcome! Feel free to fork the repository and submit improvements.

## 🛠️ Requirements
- Ubuntu 20.04 / 22.04 (EC2)
- Root access
- **UDP port 51820 must be open in AWS Security Group**