#!/usr/bin/env bash

set -e

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Root privilege check
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run this script as root.${NC}"
    exit 1
fi

# Get server public IP
get_public_ip() {
    curl -s4 https://api.ipify.org || curl -s4 https://ifconfig.me || echo "127.0.0.1"
}

# Install dependencies and GOST binary
install_dependencies() {
    echo -e "${YELLOW}[+] Checking and installing dependencies...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget tar iptables netcat-openbsd >/dev/null 2>&1

    if ! command -v gost &>/dev/null; then
        echo -e "${YELLOW}[+] Downloading and installing GOST...${NC}"
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) GOST_ARCH="linux-amd64" ;;
            aarch64) GOST_ARCH="linux-arm64" ;;
            armv7l) GOST_ARCH="linux-armv7" ;;
            *) echo -e "${RED}[!] Architecture $ARCH is not supported.${NC}"; exit 1 ;;
        esac

        LATEST_URL=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep "browser_download_url.*${GOST_ARCH}.*tar.gz" | head -n 1 | cut -d '"' -f 4)
        if [ -z "$LATEST_URL" ]; then
            LATEST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_${GOST_ARCH}.tar.gz"
        fi

        wget -qO /tmp/gost.tar.gz "$LATEST_URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        rm -rf /tmp/gost*
        echo -e "${GREEN}[✓] GOST installed successfully.${NC}"
    else
        echo -e "${GREEN}[✓] GOST is already installed.${NC}"
    fi
}

# Generate random secure key
generate_random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# Network connection and port tester
test_connectivity() {
    echo -e "\n${CYAN}--- Network & Port Connectivity Test ---${NC}"
    read -p "Destination IP / Hostname: " TEST_HOST
    read -p "Destination Port: " TEST_PORT
    read -p "Protocol (1: TCP | 2: UDP) [Default 1]: " PROTO_CHOICE

    if [ -z "$TEST_HOST" ] || [ -z "$TEST_PORT" ]; then
        echo -e "${RED}[!] Host and port cannot be empty.${NC}"
        return
    fi

    echo -e "${YELLOW}[*] Performing ICMP ping to $TEST_HOST...${NC}"
    ping -c 4 "$TEST_HOST" || echo -e "${YELLOW}[!] ICMP ping did not respond (may be blocked by firewall).${NC}"

    if [ "$PROTO_CHOICE" == "2" ]; then
        echo -e "${YELLOW}[*] Sending UDP probe to $TEST_HOST:$TEST_PORT...${NC}"
        if nc -z -v -u -w3 "$TEST_HOST" "$TEST_PORT" 2>&1 | grep -q -E "succeeded|open"; then
            echo -e "${GREEN}[✓] UDP connection open / responded.${NC}"
        else
            echo -e "${YELLOW}[!] UDP probe returned ambiguous status (normal behavior for raw UDP endpoints).${NC}"
        fi
    else
        echo -e "${YELLOW}[*] Testing TCP connection to $TEST_HOST:$TEST_PORT...${NC}"
        if nc -z -v -w3 "$TEST_HOST" "$TEST_PORT" 2>&1 | grep -q -E "succeeded|open"; then
            echo -e "${GREEN}[✓] TCP port is open and reachable.${NC}"
        else
            echo -e "${RED}[✗] TCP connection failed (port closed or blocked by firewall).${NC}"
        fi
    fi
}

# Setup Relay Server (Outside Server)
setup_server() {
    install_dependencies

    echo -e "\n${CYAN}--- Setup Remote Server (Relay Node) ---${NC}"

    read -p "Enter tunnel identifier/name [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-server-${TUNNEL_NAME}"

    read -p "KCP listening port on this server [Default: 8443]: " KCP_PORT
    KCP_PORT=${KCP_PORT:-8443}

    SUGGESTED_KEY=$(generate_random_key)
    echo -e "Suggested encryption key: ${GREEN}$SUGGESTED_KEY${NC}"
    read -p "Encryption key (Press Enter to use suggested): " CIPHER_KEY
    CIPHER_KEY=${CIPHER_KEY:-$SUGGESTED_KEY}

    # Open port in iptables
    iptables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true

    # Create systemd service
    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=GOST Encrypted KCP Server - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -L "relay+kcp://:${KCP_PORT}?nodelay=1&interval=5&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=1350&crypt=aes&key=${CIPHER_KEY}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    echo -e "\n${GREEN}[✓] Remote Server setup completed successfully.${NC}"
    echo -e "Service Name: ${CYAN}${SERVICE_NAME}${NC}"
    echo -e "KCP Port: ${CYAN}${KCP_PORT}${NC}"
    echo -e "Security Key: ${YELLOW}${CIPHER_KEY}${NC}"
    echo -e "\n${YELLOW}[!] Keep this key safe and use it when setting up the Forwarder node.${NC}"
}

# Setup Forwarder Client (Iran / Local Server)
setup_client() {
    install_dependencies

    echo -e "\n${CYAN}--- Setup Forwarder Node (Local Server) ---${NC}"

    read -p "Enter tunnel identifier/name [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-client-${TUNNEL_NAME}"

    read -p "Remote Server IP / Hostname: " REMOTE_IP
    while [ -z "$REMOTE_IP" ]; do
        echo -e "${RED}[!] Remote server address cannot be empty.${NC}"
        read -p "Remote Server IP / Hostname: " REMOTE_IP
    done

    read -p "Remote KCP tunnel port [Default: 8443]: " REMOTE_KCP_PORT
    REMOTE_KCP_PORT=${REMOTE_KCP_PORT:-8443}

    read -p "Local inbound port for clients [Default: 2053]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-2053}

    read -p "Destination port on remote server [Default: same as local $LOCAL_PORT]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-$LOCAL_PORT}

    read -p "Security Key (must match Remote Server): " CIPHER_KEY
    while [ -z "$CIPHER_KEY" ]; do
        echo -e "${RED}[!] Security key cannot be empty.${NC}"
        read -p "Security Key: " CIPHER_KEY
    done

    # Open local ports in iptables
    iptables -I INPUT -p tcp --dport "$LOCAL_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$LOCAL_PORT" -j ACCEPT 2>/dev/null || true

    # Create systemd service
    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=GOST Encrypted KCP Client - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -L "tcp://:${LOCAL_PORT}/127.0.0.1:${TARGET_PORT}" -L "udp://:${LOCAL_PORT}/127.0.0.1:${TARGET_PORT}" -F "relay+kcp://${REMOTE_IP}:${REMOTE_KCP_PORT}?nodelay=1&interval=5&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=1350&crypt=aes&key=${CIPHER_KEY}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    echo -e "\n${GREEN}[✓] Forwarder Node setup completed successfully.${NC}"
    echo -e "Service Name: ${CYAN}${SERVICE_NAME}${NC}"
    echo -e "Inbound Port: ${CYAN}${LOCAL_PORT}${NC}"
    echo -e "Forwarding To: ${CYAN}${REMOTE_IP}:${TARGET_PORT}${NC}"
}

# Manage running tunnels
manage_services() {
    echo -e "\n${CYAN}--- Manage Existing Tunnels ---${NC}"
    SERVICES=$(systemctl list-unit-files | grep -E "gost-(server|client)" | awk '{print $1}')

    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}No active GOST tunnels found.${NC}"
        return
    fi

    echo "Available services:"
    echo "$SERVICES"
    echo "-----------------------------------"
    read -p "Enter service name to manage (e.g. gost-client-main): " TARGET_SVC

    if [ -z "$TARGET_SVC" ]; then
        return
    fi

    echo "1. Service Status"
    echo "2. View Live Logs"
    echo "3. Restart Service"
    echo "4. Stop and Delete Tunnel"
    read -p "Select action [1-4]: " SVC_ACTION

    case $SVC_ACTION in
        1) systemctl status "$TARGET_SVC" --no-pager ;;
        2) journalctl -u "$TARGET_SVC" -f -n 20 ;;
        3) systemctl restart "$TARGET_SVC" && echo -e "${GREEN}[✓] Service restarted.${NC}" ;;
        4)
            systemctl stop "$TARGET_SVC"
            systemctl disable "$TARGET_SVC" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${TARGET_SVC}.service"
            systemctl daemon-reload
            echo -e "${GREEN}[✓] Tunnel deleted successfully.${NC}"
            ;;
        *) echo -e "${RED}[!] Invalid choice.${NC}" ;;
    esac
}

# Main menu
main_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${GREEN}       GOST KCP+AES Tunnel Manager            ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo "1. Setup Remote Server (Relay Node)"
    echo "2. Setup Forwarder Node (Local Client)"
    echo "3. Test Network Connection & Port"
    echo "4. Manage Tunnels (Status, Logs, Delete)"
    echo "5. Exit"
    echo -e "${CYAN}==============================================${NC}"
    read -p "Enter choice [1-5]: " CHOICE

    case $CHOICE in
        1) setup_server ;;
        2) setup_client ;;
        3) test_connectivity ;;
        4) manage_services ;;
        5) exit 0 ;;
        *) echo -e "${RED}[!] Invalid choice.${NC}" ;;
    esac
}

main_menu
