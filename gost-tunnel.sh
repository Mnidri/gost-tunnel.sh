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
    echo -e "${RED}[!] Lotfan ba dastresi root ejra konid (sudo -i).${NC}"
    exit 1
fi

# Detect Public IP
get_public_ip() {
    curl -s4 --max-time 3 https://api.ipify.org || curl -s4 --max-time 3 https://ifconfig.me || echo "127.0.0.1"
}

# Install GOST and Tools
install_dependencies() {
    echo -e "${YELLOW}[+] Dar hale barresi va nasbe pish-niazha...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget tar iptables netcat-openbsd iputils-ping nano >/dev/null 2>&1

    if ! command -v gost &>/dev/null; then
        echo -e "${YELLOW}[+] GOST peyda nashod. Dar hale download va nasb...${NC}"
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) GOST_ARCH="linux-amd64" ;;
            aarch64) GOST_ARCH="linux-arm64" ;;
            armv7l) GOST_ARCH="linux-armv7" ;;
            *) echo -e "${RED}[!] Memari CPU ($ARCH) support nemishavad.${NC}"; exit 1 ;;
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
        echo -e "${GREEN}[✓] GOST ba movafaghiat nasb shod.${NC}"
    fi
}

generate_random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# 1. Setup Server (Kharej)
setup_kharej() {
    install_dependencies
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}   STEP 1: Setup Server KHAREJ (Outside Node)    ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}In marhale bayad AVAL rooye server Kharej ejra shavad.${NC}\n"

    read -p "Tunnel Name / Shenaseye Tunnel [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-server-${TUNNEL_NAME}"

    read -p "KCP Tunnel Port rooye Kharej [Default: 8443]: " KCP_PORT
    KCP_PORT=${KCP_PORT:-8443}

    read -p "MTU Size [Default: 1350]: " MTU_SIZE
    MTU_SIZE=${MTU_SIZE:-1350}

    SUGGESTED_KEY=$(generate_random_key)
    echo -e "Pishnahad Password: ${GREEN}$SUGGESTED_KEY${NC}"
    read -p "Secret Encryption Key (Enter bezanid ta hamin set shavad): " CIPHER_KEY
    CIPHER_KEY=${CIPHER_KEY:-$SUGGESTED_KEY}

    iptables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true

    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=GOST KCP Server - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -L "relay+kcp://:${KCP_PORT}?nodelay=1&interval=5&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=${MTU_SIZE}&crypt=aes&key=${CIPHER_KEY}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    MY_IP=$(get_public_ip)
    echo -e "\n${GREEN}[✓] Server Kharej ba movafaghiat run shod!${NC}"
    echo -e "--------------------------------------------------"
    echo -e "Tunnel Name : ${CYAN}${TUNNEL_NAME}${NC}"
    echo -e "Server IP   : ${CYAN}${MY_IP}${NC}"
    echo -e "KCP Port    : ${CYAN}${KCP_PORT}${NC}"
    echo -e "MTU         : ${CYAN}${MTU_SIZE}${NC}"
    echo -e "Secret Key  : ${YELLOW}${CIPHER_KEY}${NC}"
    echo -e "--------------------------------------------------"
    read -p "Enter bezanid ta be menu bargardid..." DUMMY
}

# 2. Setup Client (Iran)
setup_iran() {
    install_dependencies
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}    STEP 2: Setup Server IRAN (Client/Relay)     ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${YELLOW}In marhale rooye server IRAN ejra mishavad.${NC}\n"

    read -p "Tunnel Name (Baraye jelogiri az tadakhol) [Default: main]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-main}
    SERVICE_NAME="gost-client-${TUNNEL_NAME}"

    read -p "IP Server Kharej (Remote Server IP): " REMOTE_IP
    while [ -z "$REMOTE_IP" ]; do
        echo -e "${RED}[!] IP nemitavanad khali bashad.${NC}"
        read -p "IP Server Kharej: " REMOTE_IP
    done

    read -p "KCP Port Server Kharej [Default: 8443]: " REMOTE_KCP_PORT
    REMOTE_KCP_PORT=${REMOTE_KCP_PORT:-8443}

    read -p "Port-haie ke mikhahid forward shavand (Masalan: 2053 ya 2053,443,80) [Default: 2053]: " FORWARD_PORTS
    FORWARD_PORTS=${FORWARD_PORTS:-2053}

    read -p "MTU Size (Bayad ba Kharej yeki bashad) [Default: 1350]: " MTU_SIZE
    MTU_SIZE=${MTU_SIZE:-1350}

    read -p "Secret Key (Daghighan hamoon ke tooye Kharej zadid): " CIPHER_KEY
    while [ -z "$CIPHER_KEY" ]; do
        echo -e "${RED}[!] Key nemitavanad khali bashad.${NC}"
        read -p "Secret Key: " CIPHER_KEY
    done

    IFS=',' read -ra PORT_LIST <<< "$FORWARD_PORTS"
    LISTEN_ARGS=""
    for PORT in "${PORT_LIST[@]}"; do
        P=$(echo "$PORT" | tr -d ' ')
        LISTEN_ARGS="${LISTEN_ARGS} -L \"tcp://:${P}/127.0.0.1:${P}\" -L \"udp://:${P}/127.0.0.1:${P}\""
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
ExecStart=/usr/local/bin/gost ${LISTEN_ARGS} -F "relay+kcp://${REMOTE_IP}:${REMOTE_KCP_PORT}?nodelay=1&interval=5&resend=1&nc=1&sndwnd=4096&rcvwnd=4096&mtu=${MTU_SIZE}&crypt=aes&key=${CIPHER_KEY}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"

    echo -e "\n${GREEN}[✓] Server IRAN ba movafaghiat connect shod!${NC}"
    echo -e "--------------------------------------------------"
    echo -e "Service Name   : ${CYAN}${SERVICE_NAME}${NC}"
    echo -e "Forward Ports  : ${CYAN}${FORWARD_PORTS}${NC}"
    echo -e "Kharej Address : ${CYAN}${REMOTE_IP}:${REMOTE_KCP_PORT}${NC}"
    echo -e "MTU            : ${CYAN}${MTU_SIZE}${NC}"
    echo -e "--------------------------------------------------"
    read -p "Enter bezanid ta be menu bargardid..." DUMMY
}

# 3. Smart Network & MTU Diagnostic
test_network() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${GREEN}     Smart Network & MTU Diagnostic Tool          ${NC}"
    echo -e "${CYAN}==================================================${NC}"

    read -p "IP Server Maghsad (Kharej): " DEST_IP
    if [ -z "$DEST_IP" ]; then
        echo -e "${RED}[!] IP khali ast.${NC}"
        return
    fi

    read -p "Port KCP (UDP) ya Port Service [Default: 8443]: " DEST_PORT
    DEST_PORT=${DEST_PORT:-8443}

    echo -e "\n${YELLOW}[1] Test Ping va Packet Loss...${NC}"
    ping -c 4 "$DEST_IP" || echo -e "${RED}[!] ICMP Block ast.${NC}"

    echo -e "\n${YELLOW}[2] Test Port ba Netcat...${NC}"
    if nc -z -v -w3 "$DEST_IP" "$DEST_PORT" 2>&1 | grep -q -E "succeeded|open"; then
        echo -e "${GREEN}[✓] Port ${DEST_PORT} baz ast va pasokh midahad (TCP).${NC}"
    else
        echo -e "${YELLOW}[!] Pasokhi daryaft nashod (Dar soorate KCP/UDP in mored tabiee ast).${NC}"
    fi

    echo -e "\n${YELLOW}[3] Test MTU Sweeping (Barresi behtarin MTU bedoone Packet Drop)...${NC}"
    MTU_TESTS=(1500 1450 1400 1350 1300 1250)
    BEST_MTU=1350

    for MTU in "${MTU_TESTS[@]}"; do
        PACKET_SIZE=$((MTU - 28))
        echo -ne "Testing MTU ${MTU} (Payload: ${PACKET_SIZE})... "
        if ping -M do -s "$PACKET_SIZE" -c 2 -W 2 "$DEST_IP" >/dev/null 2>&1; then
            echo -e "${GREEN}OK (Bedoone Fragment)${NC}"
            BEST_MTU=$MTU
            break
        else
            echo -e "${RED}Fragmented / Dropped${NC}"
        fi
    done

    echo -e "\n--------------------------------------------------"
    echo -e "Pishnahad baraye MTU Tunnel: ${GREEN}${BEST_MTU}${NC}"
    echo -e "--------------------------------------------------"
    read -p "Enter bezanid ta be menu bargardid..." DUMMY
}

# 4 & 5. Unified Interactive Tunnel Selector & Manager
tunnel_selector_action() {
    local ACTION_MODE="$1"  # "delete", "edit", or "manage"
    clear
    echo -e "${CYAN}==================================================================${NC}"
    echo -e "${GREEN}                  LIST VA VAZIATE TUNNEL-HA                       ${NC}"
    echo -e "${CYAN}==================================================================${NC}"

    # Find services
    mapfile -t SVC_FILES < <(ls /etc/systemd/system/gost-*.service 2>/dev/null || true)

    if [ ${#SVC_FILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}Hich tunnele gost nasb shodeii rooye in server yaft nashod!${NC}"
        read -p "Enter bezanid ta be menu bargardid..." DUMMY
        return
    fi

    local INDEX=1
    declare -A SVC_MAP

    for FILE in "${SVC_FILES[@]}"; do
        SVC_NAME=$(basename "$FILE" .service)
        SVC_MAP[$INDEX]="$SVC_NAME"

        # Check Active Status
        if systemctl is-active --quiet "$SVC_NAME"; then
            STATUS_STR="${GREEN}● ACTIVE${NC}"
        else
            STATUS_STR="${RED}○ INACTIVE / STOPPED${NC}"
        fi

        # Parse ExecStart line
        EXEC_LINE=$(grep "^ExecStart=" "$FILE" 2>/dev/null || echo "")

        # Extract MTU
        MTU_VAL=$(echo "$EXEC_LINE" | grep -o 'mtu=[0-9]*' | cut -d '=' -f 2 || echo "Default")
        [ -z "$MTU_VAL" ] && MTU_VAL="1350"

        # Check if Kharej (Server) or Iran (Client)
        if [[ "$SVC_NAME" == *"server"* ]]; then
            ROLE="${MAGENTA}[KHAREJ / SERVER]${NC}"
            KCP_P=$(echo "$EXEC_LINE" | grep -o 'relay+kcp://:[0-9]*' | cut -d ':' -f 2 || echo "Unknown")
            DETAILS="KCP Listen Port: ${CYAN}${KCP_P}${NC} | MTU: ${CYAN}${MTU_VAL}${NC}"
        else
            ROLE="${BLUE}[IRAN / CLIENT]${NC}"
            # Extract Local Ports
            PORTS_FWD=$(echo "$EXEC_LINE" | grep -o 'tcp://:[0-9]*/' | sed 's/tcp:\/\/://g' | sed 's/\///g' | tr '\n' ',' | sed 's/,$//')
            [ -z "$PORTS_FWD" ] && PORTS_FWD="Unknown"
            # Extract Remote Dest
            REMOTE_DEST=$(echo "$EXEC_LINE" | grep -o 'relay+kcp://[^?]*' | sed 's/relay+kcp:\/\///')
            [ -z "$REMOTE_DEST" ] && REMOTE_DEST="Unknown"
            DETAILS="Forward Ports: ${CYAN}${PORTS_FWD}${NC} -> Dest: ${CYAN}${REMOTE_DEST}${NC} | MTU: ${CYAN}${MTU_VAL}${NC}"
        fi

        echo -e "${YELLOW}[${INDEX}]${NC} Service: ${GREEN}${SVC_NAME}${NC} | Status: ${STATUS_STR}"
        echo -e "    Role: ${ROLE} | ${DETAILS}"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"
        ((INDEX++))
    done

    echo -e "${YELLOW}[0]${NC} Bazgasht be Menu Asli"
    echo -e "${CYAN}==================================================================${NC}"
    read -p "Shomareye tunnel ra entekhab konid [0-$((INDEX-1))]: " SELECTED_NUM

    if [ "$SELECTED_NUM" == "0" ] || [ -z "$SELECTED_NUM" ]; then
        return
    fi

    CHOSEN_SVC="${SVC_MAP[$SELECTED_NUM]}"
    if [ -z "$CHOSEN_SVC" ]; then
        echo -e "${RED}[!] Shomareye entekhab shode na-motabar ast.${NC}"
        sleep 2
        return
    fi

    # Perform action based on mode
    if [ "$ACTION_MODE" == "delete" ]; then
        echo -e "\n${RED}Shoma dar hale pak kardane tunnel: ${YELLOW}${CHOSEN_SVC}${RED} hastid!${NC}"
        read -p "Aya motmaen hastid? (y/n) [Default: n]: " CONFIRM_DEL
        if [[ "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
            systemctl stop "$CHOSEN_SVC" 2>/dev/null || true
            systemctl disable "$CHOSEN_SVC" 2>/dev/null || true
            rm -f "/etc/systemd/system/${CHOSEN_SVC}.service"
            systemctl daemon-reload
            echo -e "${GREEN}[✓] Tunnel ${CHOSEN_SVC} ba movafaghiat kamelan pak shod.${NC}"
        else
            echo -e "${YELLOW}[*] Amaliate hazf laghv shod.${NC}"
        fi
        read -p "Enter bezanid..." DUMMY

    elif [ "$ACTION_MODE" == "edit" ]; then
        echo -e "\n${CYAN}--- Virayeshe Tunnel: ${GREEN}${CHOSEN_SVC}${CYAN} ---${NC}"
        echo "1. Virayeshe MTU (Sari va Automatic)"
        echo "2. Baz kardane config tooye Nano (Edit dastori)"
        echo "3. Restart Kardane Service"
        echo "4. Bazgasht"
        read -p "Entekhab konid [1-4]: " EDIT_CHOICE

        case $EDIT_CHOICE in
            1)
                read -p "MTU jadid ra vared konid [Masalan 1300]: " NEW_MTU
                if [ -n "$NEW_MTU" ]; then
                    sed -i -E "s/mtu=[0-9]+/mtu=${NEW_MTU}/g" "/etc/systemd/system/${CHOSEN_SVC}.service"
                    systemctl daemon-reload
                    systemctl restart "$CHOSEN_SVC"
                    echo -e "${GREEN}[✓] MTU be ${NEW_MTU} taghir yaft va tunnel restart shod.${NC}"
                fi
                read -p "Enter bezanid..." DUMMY
                ;;
            2)
                nano "/etc/systemd/system/${CHOSEN_SVC}.service"
                systemctl daemon-reload
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Taghirat zakhire va tunnel restart shod.${NC}"
                read -p "Enter bezanid..." DUMMY
                ;;
            3)
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Service restart shod.${NC}"
                sleep 2
                ;;
            *) return ;;
        esac

    elif [ "$ACTION_MODE" == "manage" ]; then
        echo -e "\n${CYAN}--- Modiriate Tunnel: ${GREEN}${CHOSEN_SVC}${CYAN} ---${NC}"
        echo "1. Moshahedeye Status daghigh (Systemctl Status)"
        echo "2. Moshahedeye Live Logs (Zende)"
        echo "3. Restart Kardane Service"
        echo "4. Stop / Start Service"
        echo "5. Bazgasht"
        read -p "Entekhab konid [1-5]: " MNG_CHOICE

        case $MNG_CHOICE in
            1)
                systemctl status "$CHOSEN_SVC" --no-pager
                read -p "Enter bezanid..." DUMMY
                ;;
            2)
                echo -e "${YELLOW}[!] Baraye khorooj az halate log Ctrl+C ra bezanid.${NC}"
                sleep 1
                journalctl -u "$CHOSEN_SVC" -f -n 30
                ;;
            3)
                systemctl restart "$CHOSEN_SVC"
                echo -e "${GREEN}[✓] Service restart shod.${NC}"
                sleep 2
                ;;
            4)
                if systemctl is-active --quiet "$CHOSEN_SVC"; then
                    systemctl stop "$CHOSEN_SVC"
                    echo -e "${YELLOW}[!] Service Stop shod.${NC}"
                else
                    systemctl start "$CHOSEN_SVC"
                    echo -e "${GREEN}[✓] Service Start shod.${NC}"
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
        echo -e "${GREEN}         GOST KCP+AES Dual-Tunnel Manager         ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo -e "1. ${BLUE}[AVAL INJA]${NC} Setup Server KHAREJ (Outside Node)"
        echo -e "2. ${BLUE}[DOVVOM INJA]${NC} Setup Server IRAN (Client/Relay)"
        echo -e "3. Smart Network & Auto MTU Diagnostic (Test Ettesal)"
        echo -e "4. ${YELLOW}[EDIT]${NC} List va Virayeshe Tunnel-ha (MTU, Config)"
        echo -e "5. ${RED}[DELETE]${NC} List va Hazfe Sari-e Tunnel-ha (Ba Shomare)"
        echo -e "6. ${MAGENTA}[STATUS/LOG]${NC} Modiriat, Status va Log-e Zende"
        echo -e "7. Exit"
        echo -e "${CYAN}==================================================${NC}"
        read -p "Lotfan yek gozine ra entekhab konid [1-7]: " MENU_CHOICE

        case $MENU_CHOICE in
            1) setup_kharej ;;
            2) setup_iran ;;
            3) test_network ;;
            4) tunnel_selector_action "edit" ;;
            5) tunnel_selector_action "delete" ;;
            6) tunnel_selector_action "manage" ;;
            7) exit 0 ;;
            *)
                echo -e "${RED}[!] Entekhab eshtebah ast.${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu
