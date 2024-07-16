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

function installQuestions() {
    echo "Welcome to the L2TP/IPsec installer!"
    echo "I need to ask you a few questions before starting the setup."
    echo "You can keep the default options and just press enter if you are ok with them."
    echo ""

    read -rp "VPN server IP: " -e -i "$(hostname -I | awk '{print $1}')" VPN_SERVER_IP
    read -rp "IPsec PSK: " -e -i "mypresharedkey" IPSEC_PSK
    read -rp "VPN username: " -e -i "vpnuser" VPN_USER
    read -rp "VPN password: " -e -i "vpnpassword" VPN_PASSWORD
    read -rp "VPN local subnet (e.g., 192.168.42.0/24): " -e -i "192.168.42.0/24" VPN_SUBNET
}

function installL2TP() {
    # Run setup questions first
    installQuestions

    apt-get update
    apt-get install -y strongswan xl2tpd

    cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=never
conn %default
    keyexchange=ikev1
    authby=secret
conn L2TP-PSK-NAT
    rightsubnet=vhost:%priv
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

    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = yes
[lns default]
ip range = ${VPN_SUBNET%.*}.10-${VPN_SUBNET%.*}.100
local ip = ${VPN_SUBNET%.*}.1
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP VPN Server
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
refuse-mschap
require-mppe-128
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
crtscts
idle 1800
mtu 1410
mru 1410
lock
connect-delay 5000
EOF

    echo "$VPN_USER * $VPN_PASSWORD *" >> /etc/ppp/chap-secrets

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
net.ipv4.conf.eth0.send_redirects = 0
net.ipv4.conf.eth0.accept_redirects = 0
EOF

    sysctl --system

    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables-save > /etc/iptables.rules

    cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF

    chmod +x /etc/network/if-up.d/iptables

    systemctl enable strongswan
    systemctl enable xl2tpd
    systemctl start strongswan
    systemctl start xl2tpd

    echo -e "${GREEN}L2TP/IPsec VPN is installed and configured.${NC}"
    touch /etc/l2tp_vpn_installed
}

function addClient() {
    read -rp "VPN username: " VPN_USER
    read -rp "VPN password: " VPN_PASSWORD

    echo "$VPN_USER * $VPN_PASSWORD *" >> /etc/ppp/chap-secrets

    systemctl restart strongswan xl2tpd
    echo -e "${GREEN}Client added successfully.${NC}"
}

function removeClient() {
    read -rp "VPN username to remove: " VPN_USER

    sed -i "/^$VPN_USER /d" /etc/ppp/chap-secrets

    systemctl restart strongswan xl2tpd
    echo -e "${GREEN}Client removed successfully.${NC}"
}

function listClients() {
    echo -e "${GREEN}Active VPN Clients:${NC}"
    awk '{print $1}' /etc/ppp/chap-secrets
}

function manageMenu() {
    echo "Welcome to the L2TP/IPsec management script!"
    echo "It looks like L2TP/IPsec is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new client"
    echo "   2) Remove an existing client"
    echo "   3) List all clients"
    echo "   4) Exit"

    until [[ ${MENU_OPTION} =~ ^[1-4]$ ]]; do
        read -rp "Select an option [1-4]: " MENU_OPTION
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
