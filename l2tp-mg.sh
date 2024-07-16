#!/bin/bash

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'
REV="1"

function isRoot() {
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
}

function checkOS() {
    source /etc/os-release
    OS="${ID}"
    if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
        if [[ ${VERSION_ID} -lt 10 ]]; then
            echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
            exit 1
        fi
        OS=debian # overwrite if raspbian
    elif [[ ${OS} == "ubuntu" ]]; then
        RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
        if [[ ${RELEASE_YEAR} -lt 18 ]]; then
            echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
            exit 1
        fi
    else
        echo "Looks like you aren't running this installer on a Debian/Raspbian or Ubuntu system"
        exit 1
    fi
}

function initialCheck() {
    isRoot
    checkOS
}

function getDefaultInterface() {
    DEFAULT_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "$DEFAULT_INTERFACE"
}

function valid_ip() {
    local ip=$1
    local valid=1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        valid=$?
    fi
    return $valid
}

function prompt_ip() {
    local prompt_message=$1
    local default_value=$2
    local ip

    while true; do
        read -rp "$prompt_message: " -e -i "$default_value" ip
        if valid_ip "$ip"; then
            echo "$ip"
            return
        else
            echo -e "${RED}Invalid IP address. Please enter a valid IP address.${NC}"
        fi
    done
}

function installQuestions() {
    echo "Welcome to the L2TP installer!"
    echo "I need to ask you a few questions before starting the setup."
    echo "You can keep the default options and just press enter if you are ok with them."
    echo ""

    current_second=$(date +%S)
    default_subnet="10.${current_second}.${current_second}.0/24"
    default_interface=$(getDefaultInterface)

    VPN_SERVER_IP=$(prompt_ip "VPN server IP" "$(hostname -I | awk '{print $1}')")
    read -rp "Do you want to use L2TP with IPsec (pre-shared key)? [y/n]: " -e -i "y" USE_IPSEC
    if [[ "$USE_IPSEC" =~ ^[Yy]$ ]]; then
        read -rp "IPsec PSK: " -e -i "iamthepresharedkey" IPSEC_PSK
    else
        read -rp "L2TP Secret: " -e -i "mylt2psecret" L2TP_SECRET
    fi
    read -rp "VPN username: " -e -i "vpnuser" VPN_USER
    read -rp "VPN password: " -e -i "vpnpassword" VPN_PASSWORD
    VPN_SUBNET=$(prompt_ip "VPN local subnet (e.g., 10.x.x.0/24)" "$default_subnet")
    read -rp "Network interface name (e.g., eth0): " -e -i "$default_interface" INTERFACE_NAME
}

function installL2TP() {
    installQuestions

    apt-get update
    apt-get install -y xl2tpd ppp iptables

    if [[ "$USE_IPSEC" =~ ^[Yy]$ ]]; then
        apt-get install -y strongswan

        cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=never
conn %default
    keyexchange=ikev1
    authby=secret
conn L2TP-PSK-NAT
    rightsubnet=0.0.0.0/0
    also=L2TP-PSK-noNAT
conn L2TP-PSK-noNAT
    keyexchange=ikev1
    left=$VPN_SERVER_IP
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    auto=add
EOF

        cat > /etc/ipsec.secrets <<EOF
$VPN_SERVER_IP : PSK "$IPSEC_PSK"
EOF

        systemctl enable strongswan-starter
        systemctl start strongswan-starter
    else
        # Add L2TP secret to xl2tpd configuration
        cat > /etc/xl2tpd/l2tp-secrets <<EOF
* * "$L2TP_SECRET"
EOF
    fi

    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = no

[lns default]
ip range = ${VPN_SUBNET%.*}.10-${VPN_SUBNET%.*}.100
local ip = ${VPN_SUBNET%.*}.1
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP VPN Server
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    if [[ -z "$USE_IPSEC" ]]; then
        echo "secret = $L2TP_SECRET" >> /etc/xl2tpd/xl2tpd.conf
    fi

    cat > /etc/ppp/options.xl2tpd <<EOF
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
crtscts
idle 1800
mtu 1410
mru 1410
lock
connect-delay 5000
debug
EOF

    echo "$VPN_USER * $VPN_PASSWORD *" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets

    cat > /etc/sysctl.d/99-sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.$INTERFACE_NAME.send_redirects = 0
net.ipv4.conf.$INTERFACE_NAME.accept_redirects = 0
EOF

    sysctl --system

    cat > /etc/l2tp_vpn_iptables.sh <<EOF
#!/bin/sh
iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -s ${VPN_SUBNET%.*}.0/24 -j ACCEPT
EOF

    chmod +x /etc/l2tp_vpn_iptables.sh

    cat > /etc/systemd/system/l2tp-iptables.service <<EOF
[Unit]
Description=Apply iptables rules for L2TP
After=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/l2tp_vpn_iptables.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable l2tp-iptables.service
    systemctl start l2tp-iptables.service

    systemctl enable xl2tpd
    systemctl start xl2tpd

    echo -e "${GREEN}L2TP VPN is installed and configured.${NC}"
    touch /etc/l2tp_vpn_installed
}

function toggleDebug() {
    if grep -q "debug tunnel = yes" /etc/xl2tpd/xl2tpd.conf; then
        sed -i '/debug tunnel = yes/d' /etc/xl2tpd/xl2tpd.conf
        sed -i '/debug packet = yes/d' /etc/xl2tpd/xl2tpd.conf
        sed -i '/debug avp = yes/d' /etc/xl2tpd/xl2tpd.conf
        sed -i '/debug network = yes/d' /etc/xl2tpd/xl2tpd.conf
        sed -i '/debug state = yes/d' /etc/xl2tpd/xl2tpd.conf
        echo -e "${GREEN}Debug mode disabled.${NC}"
    else
        sed -i '/\[global\]/a debug tunnel = yes\ndebug packet = yes\ndebug avp = yes\ndebug network = yes\ndebug state = yes' /etc/xl2tpd/xl2tpd.conf
        echo -e "${GREEN}Debug mode enabled.${NC}"
    fi
    systemctl restart xl2tpd
}

function getNextClientIP() {
    local base_ip=$(echo $VPN_SUBNET | cut -d'.' -f1-3)
    local last_ip=$(grep -oP "${base_ip}\.\K\d+" /etc/ppp/chap-secrets | sort -n | tail -n1)
    if [[ -z "$last_ip" ]]; then
        echo "${base_ip}.10"
    else
        next_ip=$((last_ip + 1))
        echo "${base_ip}.${next_ip}"
    fi
}

function addClient() {
    read -rp "VPN username: " VPN_USER
    read -rp "VPN password: " VPN_PASSWORD

    CLIENT_IP=$(getNextClientIP)
    echo "$VPN_USER l2tpd $VPN_PASSWORD * $CLIENT_IP" >> /etc/ppp/chap-secrets
    chmod 600 /etc/ppp/chap-secrets

    cat > /root/${VPN_USER}_l2tp_client.conf <<EOF
VPN Server IP: $VPN_SERVER_IP
Username: $VPN_USER
Password: $VPN_PASSWORD
Client IP: $CLIENT_IP
EOF

    systemctl restart xl2tpd
    echo -e "${GREEN}Client added successfully.${NC}"
    echo -e "${GREEN}Client configuration saved to /root/${VPN_USER}_l2tp_client.conf${NC}"
}

function removeClient() {
    read -rp "VPN username to remove: " VPN_USER

    sed -i "/^$VPN_USER /d" /etc/ppp/chap-secrets

    rm -f /root/${VPN_USER}_l2tp_client.conf

    systemctl restart xl2tpd
    echo -e "${GREEN}Client removed successfully.${NC}"
}

function listClients() {
    echo -e "${GREEN}Active VPN Clients:${NC}"
    awk '{print $1}' /etc/ppp/chap-secrets
}

function checkServiceStatus() {
    local service_name=$1
    local service_display_name=$2

    echo -e "${GREEN}${service_display_name} Status:${NC}"
    if systemctl is-active --quiet "$service_name"; then
        echo -e "${GREEN}${service_name} is active (running).${NC}"
    else
        echo -e "${RED}${service_name} is not running.${NC}"
    fi

    if systemctl is-enabled --quiet "$service_name"; then
        echo -e "${GREEN}${service_name} is enabled at startup.${NC}"
    else
        echo -e "${ORANGE}${service_name} is not enabled at startup.${NC}"
    fi
}

function checkServices() {
    checkServiceStatus "xl2tpd" "xl2tpd"
    checkServiceStatus "l2tp-iptables.service" "L2TP IP Tables"
    
    if [[ "$USE_IPSEC" =~ ^[Yy]$ ]]; then
        checkServiceStatus "strongswan-starter" "strongSwan (IPsec)"
    fi

    echo -e "${GREEN}L2TP IP Tables Service Logs:${NC}"
    journalctl -u l2tp-iptables.service --no-pager -n 10
}

function uninstallL2TP() {
    systemctl stop xl2tpd l2tp-iptables.service
    systemctl disable xl2tpd l2tp-iptables.service

    if [[ "$USE_IPSEC" =~ ^[Yy]$ ]]; then
        systemctl stop strongswan-starter
        systemctl disable strongswan-starter
        apt-get remove --purge -y strongswan
    fi

    apt-get remove --purge -y xl2tpd ppp iptables
    rm -rf /etc/xl2tpd /etc/ppp/chap-secrets /etc/sysctl.d/99-sysctl.conf /etc/l2tp_vpn_iptables.sh /etc/systemd/system/l2tp-iptables.service /etc/l2tp_vpn_installed
    systemctl daemon-reload
    echo -e "${GREEN}L2TP VPN and all configurations have been removed.${NC}"
}

function manageMenu() {
    echo "Welcome to the L2TP management script!"
    echo "It looks like L2TP is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new client"
    echo "   2) Remove an existing client"
    echo "   3) List all clients"
    echo "   4) Check status of services"
    echo "   5) Toggle debug mode"
    echo "   6) Uninstall L2TP VPN"
    echo "   7) Exit"

    until [[ ${MENU_OPTION} =~ ^[1-7]$ ]]; do
        read -rp "Select an option [1-7]: " MENU_OPTION
    done

    case "${MENU_OPTION}" in
    1)
        addClient
        ;;
    2)
        removeClient
        ;;
    3)
        listClients
        ;;
    4)
        checkServices
        ;;
    5)
        toggleDebug
        ;;
    6)
        uninstallL2TP
        ;;
    7)
        exit 0
        ;;
    esac
}

initialCheck

if [[ -e /etc/l2tp_vpn_installed ]]; then
    manageMenu
else
    installL2TP
fi
