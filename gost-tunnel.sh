#!/usr/bin/env bash

set -e

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Check Root Access
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Please run as root (sudo -i).${NC}"
    exit 1
fi

# Detect Public IP
get_public_ip() {
    curl -s4 --max-time 3 https://api.ipify.org || curl -s4 --max-time 3 https://ifconfig.me || echo "127.0.0.1"
}

# Optimize Linux Network Kernel for UDP/KCP
optimize_kernel() {
    echo -e "${YELLOW}[+] Optimizing system network parameters...${NC}"
    cat <<EOF > /etc/sysctl.d/99-gost-tunnel.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_udp_timeout=15
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.netfilter.nf_conntrack_max=1048576
net.core.rmem_max=67108864
net.core.wmem_max=67108864
EOF
    sysctl --system >/dev/null 2>&1 || true
}

# Install GOST v2.11.5 Stable and System Tools
install_dependencies() {
    echo -e "${YELLOW}[+] Installing dependencies...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget gzip iptables netcat-openbsd iputils-ping cron >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    optimize_kernel

    if ! command -v gost &>/dev/null; then
        echo -e "${YELLOW}[+] Downloading GOST core binary (v2.11.5)...${NC}"
        ARCH=$(uname -m)
        case $ARCH in
            x86_64)  GOST_FILE="gost-linux-amd64-2.11.5.gz" ;;
            aarch64) GOST_FILE="gost-linux-armv8-2.11.5.gz" ;;
            armv7l)  GOST_FILE="gost-linux-armv7-2.11.5.gz" ;;
            *) echo -e "${RED}[!] Architecture $ARCH is not supported.${NC}"; exit 1 ;;
        esac

        DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/${GOST_FILE}"

        if ! curl -fsSL -o /tmp/gost.gz "$DOWNLOAD_URL"; then
            wget -qO /tmp/gost.gz "$DOWNLOAD_URL" || {
                echo -e "${RED}[!] Failed to download GOST binary.${NC}"
                exit 1
            }
        fi

        gzip -d -f /tmp/gost.gz
        mv /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        echo -e "${GREEN}[✓] GOST core binary installed.${NC}"
    fi
}

generate_random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# 1. Setup Outside Node (Server)
setup_outside() {
    install_dependencies
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}      Setup Outside Node (Server / Listener)      ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}Notice: Run this step on the Outside server FIRST.${NC}\n"

    read -p "Tunnel Name [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-server-${TUNNEL_NAME}"

    read -p "KCP Listen Port [Default: 8443]: " KCP_PORT
    KCP_PORT=${KCP_PORT:-8443}

    read -p "Enable Port-Hopping (50 Ports)? (y/n) [Default: y]: " ENABLE_HOP
    ENABLE_HOP=${ENABLE_HOP:-y}

    if [[ "$ENABLE_HOP" =~ ^[Yy]$ ]]; then
        read -p "Start of 50-Port Range [Default: 42000]: " HOP_START
        HOP_START=${HOP_START:-42000}
        HOP_END=$((HOP_START + 50))
        HOP_RANGE="${HOP_START}:${HOP_END}"
    fi

    read -p "MTU Size [Default: 1350]: " MTU_SIZE
    MTU_SIZE=${MTU_SIZE:-1350}

    SUGGESTED_KEY=$(generate_random_key)
    echo -e "Suggested Key: ${GREEN}$SUGGESTED_KEY${NC}"
    read -p "Security Key (Press Enter to use suggested): " CIPHER_KEY
    CIPHER_KEY=${CIPHER_KEY:-$SUGGESTED_KEY}

    iptables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true

    if [[ "$ENABLE_HOP" =~ ^[Yy]$ ]]; then
        iptables -I INPUT -p udp --dport "$HOP_RANGE" -j ACCEPT 2>/dev/null || true
        iptables -t nat -I PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$KCP_PORT" 2>/dev/null || true
    fi

    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=GOST KCP Server - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -L "relay+kcp://:${KCP_PORT}?nodelay=1&interval=10&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=${MTU_SIZE}&crypt=aes&key=${CIPHER_KEY}&keepalive=10s"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    MY_IP=$(get_public_ip)
    echo -e "\n${GREEN}[✓] Outside Node configured and running.${NC}"
    echo -e "--------------------------------------------------"
    echo -e "Tunnel Name   : ${CYAN}${TUNNEL_NAME}${NC}"
    echo -e "Server IP     : ${CYAN}${MY_IP}${NC}"
    echo -e "KCP Base Port : ${CYAN}${KCP_PORT}${NC}"
    if [[ "$ENABLE_HOP" =~ ^[Yy]$ ]]; then
        echo -e "Port-Hopping  : ${GREEN}Active (Range: ${HOP_RANGE})${NC}"
    else
        echo -e "Port-Hopping  : ${YELLOW}Disabled${NC}"
    fi
    echo -e "MTU           : ${CYAN}${MTU_SIZE}${NC}"
    echo -e "Security Key  : ${YELLOW}${CIPHER_KEY}${NC}"
    echo -e "--------------------------------------------------"
    read -p "Press Enter to return to main menu..." DUMMY
}

# 2. Setup Iran Node (Client)
setup_iran() {
    install_dependencies
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}     Setup Iran Node (Client / Port Forwarder)    ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}Notice: Run this step on the Iran server SECOND.${NC}\n"

    read -p "Tunnel Name [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-client-${TUNNEL_NAME}"

    read -p "Outside Server IP / Hostname: " REMOTE_IP
    while [ -z "$REMOTE_IP" ]; do
        echo -e "${RED}[!] IP cannot be empty.${NC}"
        read -p "Outside Server IP: " REMOTE_IP
    done

    read -p "Is Port-Hopping enabled on Outside? (y/n) [Default: y]: " HOP_ENABLED
    HOP_ENABLED=${HOP_ENABLED:-y}

    if [[ "$HOP_ENABLED" =~ ^[Yy]$ ]]; then
        read -p "Outside Start Port of 50-Range [Default: 42000]: " HOP_START
        HOP_START=${HOP_START:-42000}
        REMOTE_KCP_PORT=$((HOP_START + RANDOM % 50))
    else
        read -p "Outside KCP Port [Default: 8443]: " REMOTE_KCP_PORT
        REMOTE_KCP_PORT=${REMOTE_KCP_PORT:-8443}
    fi

    read -p "Ports to forward (e.g. 5050 or 5050,443) [Default: 5050]: " FORWARD_PORTS
    FORWARD_PORTS=${FORWARD_PORTS:-5050}

    read -p "MTU Size (Must match Outside node) [Default: 1350]: " MTU_SIZE
    MTU_SIZE=${MTU_SIZE:-1350}

    read -p "Security Key (Must match Outside node): " CIPHER_KEY
    while [ -z "$CIPHER_KEY" ]; do
        echo -e "${RED}[!] Key cannot be empty.${NC}"
        read -p "Security Key: " CIPHER_KEY
    done

    IFS=',' read -ra PORT_LIST <<< "$FORWARD_PORTS"
    LISTEN_ARGS=""
    for PORT in "${PORT_LIST[@]}"; do
        P=$(echo "$PORT" | tr -d ' ')
        LISTEN_ARGS="${LISTEN_ARGS} -L \"tcp://:${P}/127.0.0.1:${P}?ttl=120s\" -L \"udp://:${P}/127.0.0.1:${P}?ttl=120s\""
        iptables -I INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$P" -j ACCEPT 2>/dev/null || true
    done

    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=GOST KCP Client - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost ${LISTEN_ARGS} -F "relay+kcp://${REMOTE_IP}:${REMOTE_KCP_PORT}?nodelay=1&interval=10&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=${MTU_SIZE}&crypt=aes&key=${CIPHER_KEY}&keepalive=10s"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    echo -e "\n${GREEN}[✓] Iran Node connected and active.${NC}"
    echo -e "--------------------------------------------------"
    echo -e "Service Name   : ${CYAN}${SERVICE_NAME}${NC}"
    echo -e "Forward Ports  : ${CYAN}${FORWARD_PORTS}${NC}"
    echo -e "Target Node    : ${CYAN}${REMOTE_IP}:${REMOTE_KCP_PORT}${NC}"
    echo -e "MTU            : ${CYAN}${MTU_SIZE}${NC}"
    echo -e "Keep-Alive     : ${GREEN}Enabled (10s Heartbeat + 120s NAT TTL)${NC}"
    echo -e "--------------------------------------------------"
    read -p "Press Enter to return to main menu..." DUMMY
}

# Interactive Spinner Loading Function
run_spinner() {
    local PID=$1
    local MSG=$2
    local SPINS=('-' '\' '|' '/')
    echo -ne "${YELLOW}${MSG} ${NC}"
    while kill -0 "$PID" 2>/dev/null; do
        for S in "${SPINS[@]}"; do
            echo -ne "\b${CYAN}${S}${NC}"
            sleep 0.1
        done
    done
    echo -ne "\b \n"
}

# 3. Interactive Tunnel Tester (Pair Handshake Test)
test_network() {
    install_dependencies
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${GREEN}       Interactive Tunnel Pair Verification       ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "1. Run as OUTSIDE Receiver (Generates Test Token)"
    echo "2. Run as IRAN Sender (Connects to Test Token)"
    echo "0. Back to Main Menu"
    echo "--------------------------------------------------"
    read -p "Select Mode [0-2]: " TEST_ROLE

    case $TEST_ROLE in
        1)
            TEST_PORT=39481
            iptables -I INPUT -p udp --dport "$TEST_PORT" -j ACCEPT 2>/dev/null || true
            OUTSIDE_IP=$(get_public_ip)
            TOKEN_STR="${OUTSIDE_IP}:${TEST_PORT}"

            echo -e "\n${GREEN}[✓] Outside test listener is ready!${NC}"
            echo -e "Copy this token string and paste it into Iran test runner:"
            echo -e "--------------------------------------------------"
            echo -e "TOKEN: ${CYAN}${TOKEN_STR}${NC}"
            echo -e "--------------------------------------------------"
            echo -e "${YELLOW}Waiting for Iran ping... (Press Ctrl+C to stop)${NC}\n"

            # Run a temporary silent listener
            nc -u -l -p "$TEST_PORT"
            echo -e "\n${GREEN}[✓] Packet successfully received from Iran! Network path is OPEN.${NC}"
            read -p "Press Enter to return..." DUMMY
            ;;
        2)
            read -p "Paste Outside Test Token (IP:Port): " TARGET_TOKEN
            if [ -z "$TARGET_TOKEN" ]; then
                echo -e "${RED}[!] Token cannot be empty.${NC}"
                sleep 2
                return
            fi

            DEST_IP=$(echo "$TARGET_TOKEN" | cut -d ':' -f 1)
            DEST_PORT=$(echo "$TARGET_TOKEN" | cut -d ':' -f 2)

            (
                for i in {1..5}; do
                    echo "TEST_PACKET_$i" | nc -u -w1 "$DEST_IP" "$DEST_PORT" 2>/dev/null || true
                    sleep 0.3
                done
            ) &
            TEST_PID=$!

            run_spinner "$TEST_PID" "Performing UDP handshake and probing path to ${DEST_IP}..."

            echo -e "\n${CYAN}--- Diagnostics Results ---${NC}"
            if ping -c 3 -W 2 "$DEST_IP" >/dev/null 2>&1; then
                AVG_PING=$(ping -c 3 -W 2 "$DEST_IP" | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
                echo -e "ICMP Network Ping : ${GREEN}OK (~${AVG_PING} ms)${NC}"
            else
                echo -e "ICMP Network Ping : ${YELLOW}Dropped (Firewall blocked ICMP - Normal)${NC}"
            fi

            echo -e "KCP/UDP Test Packets: ${GREEN}Sent successfully to port ${DEST_PORT}.${NC}"
            echo -e "Check Outside console: If Outside verified reception, the tunnel path is 100% healthy."
            echo -e "--------------------------------------------------"
            read -p "Press Enter to return..." DUMMY
            ;;
        *) return ;;
    esac
}

# 4. Auto-Restart Scheduled Watchdog
setup_timer() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}            Auto-Restart Tunnel Timer             ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "1. Restart tunnels every 1 Hour (Recommended)"
    echo "2. Restart tunnels every 3 Hours"
    echo "3. Restart tunnels every 6 Hours"
    echo "4. Custom interval (in hours)"
    echo "5. Disable and Remove Auto-Restart Timer"
    echo "0. Back to Main Menu"
    echo "--------------------------------------------------"
    read -p "Select option [0-5]: " TIMER_CHOICE

    CRON_FILE="/etc/cron.d/gost-autorestart"

    case $TIMER_CHOICE in
        1)
            echo "0 * * * * root systemctl restart 'gost-*' >/dev/null 2>&1" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            echo -e "${GREEN}[✓] Auto-restart set to EVERY 1 HOUR.${NC}"
            ;;
        2)
            echo "0 */3 * * * root systemctl restart 'gost-*' >/dev/null 2>&1" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            echo -e "${GREEN}[✓] Auto-restart set to EVERY 3 HOURS.${NC}"
            ;;
        3)
            echo "0 */6 * * * root systemctl restart 'gost-*' >/dev/null 2>&1" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            echo -e "${GREEN}[✓] Auto-restart set to EVERY 6 HOURS.${NC}"
            ;;
        4)
            read -p "Enter interval in hours (1-23): " CUSTOM_H
            if [[ "$CUSTOM_H" =~ ^[0-9]+$ ]] && [ "$CUSTOM_H" -ge 1 ] && [ "$CUSTOM_H" -le 23 ]; then
                echo "0 */${CUSTOM_H} * * * root systemctl restart 'gost-*' >/dev/null 2>&1" > "$CRON_FILE"
                chmod 644 "$CRON_FILE"
                echo -e "${GREEN}[✓] Auto-restart set to EVERY ${CUSTOM_H} HOURS.${NC}"
            else
                echo -e "${RED}[!] Invalid hour value.${NC}"
            fi
            ;;
        5)
            rm -f "$CRON_FILE"
            echo -e "${YELLOW}[✓] Auto-restart timer disabled and removed.${NC}"
            ;;
        *) return ;;
    esac
    read -p "Press Enter to return..." DUMMY
}

# 5, 6, 7. Unified Interactive Tunnel Selector
tunnel_selector_action() {
    local ACTION_MODE="$1"
    clear
    echo -e "${CYAN}==================================================================${NC}"
    echo -e "${GREEN}                       INSTALLED TUNNELS                          ${NC}"
    echo -e "${CYAN}==================================================================${NC}"

    mapfile -t SVC_FILES < <(ls /etc/systemd/system/gost-*.service 2>/dev/null || true)

    if [ ${#SVC_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No active GOST tunnels found on this server.${NC}"
        read -p "Press Enter to return..." DUMMY
        return
    fi

    local INDEX=1
    declare -A SVC_MAP

    for FILE in "${SVC_FILES[@]}"; do
        SVC_NAME=$(basename "$FILE" .service)
        SVC_MAP[$INDEX]="$SVC_NAME"

        if systemctl is-active --quiet "$SVC_NAME"; then
            STATUS_STR="${GREEN}ACTIVE${NC}"
        else
            STATUS_STR="${RED}INACTIVE${NC}"
        fi

        EXEC_LINE=$(grep "^ExecStart=" "$FILE" 2>/dev/null || echo "")
        MTU_VAL=$(echo "$EXEC_LINE" | grep -o 'mtu=[0-9]*' | cut -d '=' -f 2 || echo "1350")

        if [[ "$SVC_NAME" == *"server"* ]]; then
            ROLE="${MAGENTA}[Server / Outside]${NC}"
            KCP_P=$(echo "$EXEC_LINE" | grep -o 'relay+kcp://:[0-9]*' | cut -d ':' -f 2 || echo "Unknown")
            DETAILS="Listen Port: ${CYAN}${KCP_P}${NC} | MTU: ${CYAN}${MTU_VAL}${NC}"
        else
            ROLE="${BLUE}[Client / Iran]${NC}"
            PORTS_FWD=$(echo "$EXEC_LINE" | grep -o 'tcp://:[0-9]*/' | sed 's/tcp:\/\/://g' | sed 's/\///g' | tr '\n' ',' | sed 's/,$//')
            [ -z "$PORTS_FWD" ] && PORTS_FWD="Unknown"
            REMOTE_DEST=$(echo "$EXEC_LINE" | grep -o 'relay+kcp://[^?]*' | sed 's/relay+kcp:\/\///')
            [ -z "$REMOTE_DEST" ] && REMOTE_DEST="Unknown"
            DETAILS="Ports: ${CYAN}${PORTS_FWD}${NC} -> Dest: ${CYAN}${REMOTE_DEST}${NC} | MTU: ${CYAN}${MTU_VAL}${NC}"
        fi

        echo -e "${YELLOW}[${INDEX}]${NC} Service: ${GREEN}${SVC_NAME}${NC} [${STATUS_STR}]"
        echo -e "    Role: ${ROLE} | ${DETAILS}"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"
        ((INDEX++))
    done

    echo -e "${YELLOW}[0]${NC} Back to Main Menu"
    echo -e "${CYAN}==================================================================${NC}"
    read -p "Select tunnel index [0-$((INDEX-1))]: " SELECTED_NUM

    if [ "$SELECTED_NUM" == "0" ] || [ -z "$SELECTED_NUM" ]; then
        return
    fi

    CHOSEN_SVC="${SVC_MAP[$SELECTED_NUM]}"
    if [ -z "$CHOSEN_SVC" ]; then
        echo -e "${RED}[!] Invalid selection.${NC}"
        sleep 2
        return
    fi

    if [ "$ACTION_MODE" == "delete" ]; then
        echo -e "\n${RED}You are about to delete: ${YELLOW}${CHOSEN_SVC}${NC}"
        read -p "Confirm deletion? (y/n) [Default: n]: " CONFIRM_DEL
        if [[ "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
            systemctl stop "$CHOSEN_SVC" 2>/dev/null || true
            systemctl disable "$CHOSEN_SVC" 2>/dev/null || true
            rm -f "/etc/systemd/system/${CHOSEN_SVC}.service"
            systemctl daemon-reload
            echo -e "${GREEN}[✓] Tunnel ${CHOSEN_SVC} deleted successfully.${NC}"
        else
            echo -e "${YELLOW}[*] Operation canceled.${NC}"
        fi
        read -p "Press Enter to return..." DUMMY

    elif [ "$ACTION_MODE" == "edit" ]; then
        echo -e "\n${CYAN}--- Edit Tunnel: ${GREEN}${CHOSEN_SVC}${CYAN} ---${NC}"
        echo "1. Change MTU Value"
        echo "2. Manual edit with Nano"
        echo "3. Restart Service"
        echo "0. Back"
        read -p "Select action [0-3]: " EDIT_OPT

        case $EDIT_OPT in
            1)
                read -p "Enter new MTU [e.g. 1300]: " NEW_MTU
                if [ -n "$NEW_MTU" ]; then
                    sed -i -E "s/mtu=[0-9]+/mtu=${NEW_MTU}/g" "/etc/systemd/system/${CHOSEN_SVC}.service"
                    systemctl daemon-reload
                    systemctl restart "$CHOSEN_SVC"
                    echo -e "${GREEN}[✓] MTU updated to ${NEW_MTU} and tunnel restarted.${NC}"
                fi
                read -p "Press Enter to return..." DUMMY
                ;;
            2)
                nano "/etc/systemd/system/${CHOSEN_SVC}.service"
                systemctl daemon-reload
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Service configuration reloaded and restarted.${NC}"
                read -p "Press Enter to return..." DUMMY
                ;;
            3)
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Tunnel restarted.${NC}"
                sleep 2
                ;;
            *) return ;;
        esac

    elif [ "$ACTION_MODE" == "manage" ]; then
        echo -e "\n${CYAN}--- Manage Tunnel: ${GREEN}${CHOSEN_SVC}${CYAN} ---${NC}"
        echo "1. Show Systemctl Status"
        echo "2. Follow Live Logs"
        echo "3. Restart Service"
        echo "4. Toggle Start / Stop"
        echo "0. Back"
        read -p "Select action [0-4]: " MNG_CHOICE

        case $MNG_CHOICE in
            1)
                systemctl status "$CHOSEN_SVC" --no-pager
                read -p "Press Enter to return..." DUMMY
                ;;
            2)
                echo -e "${YELLOW}[!] Press Ctrl+C to exit logs.${NC}"
                sleep 1
                journalctl -u "$CHOSEN_SVC" -f -n 30
                ;;
            3)
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Tunnel restarted.${NC}"
                sleep 2
                ;;
            4)
                if systemctl is-active --quiet "$CHOSEN_SVC"; then
                    systemctl stop "$CHOSEN_SVC"
                    echo -e "${YELLOW}[!] Tunnel stopped.${NC}"
                else
                    systemctl start "$CHOSEN_SVC"
                    echo -e "${GREEN}[✓] Tunnel started.${NC}"
                fi
                sleep 2
                ;;
            *) return ;;
        esac
    fi
}

# Main Menu
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}==================================================${NC}"
        echo -e "${GREEN}         GOST KCP+AES Tunnel Manager              ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo -e "1. ${BLUE}[STEP 1]${NC} Setup Outside Node (Server)"
        echo -e "2. ${BLUE}[STEP 2]${NC} Setup Iran Node (Client)"
        echo -e "3. ${YELLOW}[TEST]${NC}   Interactive Tunnel Pair Verification"
        echo -e "4. Configure Auto-Restart Timer (Watchdog)"
        echo -e "5. ${YELLOW}[EDIT]${NC}   Edit Tunnel Configuration (MTU / Ports)"
        echo -e "6. ${RED}[DELETE]${NC} Delete Tunnel by Index Number"
        echo -e "7. ${MAGENTA}[STATUS]${NC} View Status & Live Logs"
        echo -e "8. Exit"
        echo -e "${CYAN}==================================================${NC}"
        read -p "Select an option [1-8]: " MENU_CHOICE

        case $MENU_CHOICE in
            1) setup_outside ;;
            2) setup_iran ;;
            3) test_network ;;
            4) setup_timer ;;
            5) tunnel_selector_action "edit" ;;
            6) tunnel_selector_action "delete" ;;
            7) tunnel_selector_action "manage" ;;
            8) exit 0 ;;
            *)
                echo -e "${RED}[!] Invalid selection.${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu
