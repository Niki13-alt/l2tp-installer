#!/bin/bash
# =============================================================================
# L2TP/IPsec VPN Server — Ubuntu 22.04 / 24.04
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Проверки перед запуском
# -----------------------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "Ошибка: скрипт должен быть запущен с правами root." >&2
    exit 1
fi

# Определяем внешний интерфейс
DEFAULT_IFACE=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP '(?<=dev\s)\w+' | head -1)
if [ -z "$DEFAULT_IFACE" ]; then
    echo "Ошибка: не удалось определить сетевой интерфейс." >&2
    exit 1
fi

# Определяем внешний IP
EXTERNAL_IP=$(curl -sf --max-time 5 https://ifconfig.me \
    || curl -sf --max-time 5 https://ipinfo.io/ip \
    || curl -sf --max-time 5 https://api.ipify.org \
    || ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -z "$EXTERNAL_IP" ]; then
    echo "Ошибка: не удалось определить внешний IP." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Параметры (можно переопределить через переменные окружения)
# -----------------------------------------------------------------------------

USER_COUNT="${VPN_USER_COUNT:-5}"
VPN_LOCAL_IP="${VPN_LOCAL_IP:-192.168.42.1}"
VPN_IP_RANGE="${VPN_IP_RANGE:-192.168.42.10-192.168.42.200}"
VPN_SUBNET="192.168.42.0/24"

PSK_KEY=$(openssl rand -hex 10)

# -----------------------------------------------------------------------------
# Установка пакетов
# -----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -q \
    strongswan \
    strongswan-starter \
    libstrongswan-standard-plugins \
    libcharon-extra-plugins \
    xl2tpd \
    ppp \
    iptables-persistent \
    net-tools \
    curl

# -----------------------------------------------------------------------------
# Настройка IPsec (ipsec.conf)
# Совместимость: Windows 10/11, Android, iOS, macOS, Linux
# aes128-sha1-modp1024 — для Windows без реестрового хака
# aes256-sha256-modp2048 — современные клиенты
# -----------------------------------------------------------------------------

cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=never

conn L2TP-IPsec
    auto=add
    keyexchange=ikev1
    authby=secret
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/1701
    ike=aes256-sha256-modp2048,aes256-sha1-modp2048,aes128-sha1-modp2048,aes128-sha1-modp1024!
    esp=aes256-sha256,aes256-sha1,aes128-sha1!
    forceencaps=yes
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    rekey=no
    ikelifetime=8h
    keylife=1h
EOF

cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "$PSK_KEY"
EOF
chmod 600 /etc/ipsec.secrets

# -----------------------------------------------------------------------------
# Настройка xl2tpd
# -----------------------------------------------------------------------------

mkdir -p /etc/xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = $VPN_IP_RANGE
local ip = $VPN_LOCAL_IP
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TPVPN
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# -----------------------------------------------------------------------------
# Настройка PPP
# -----------------------------------------------------------------------------

cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
mtu 1400
mru 1400
nodefaultroute
proxyarp
connect-delay 5000
lcp-echo-interval 60
lcp-echo-failure 10
idle 1800
EOF

# -----------------------------------------------------------------------------
# Создание пользователей
# -----------------------------------------------------------------------------

mkdir -p /etc/ppp
: > /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

USER_LIST=""
for i in $(seq 1 "$USER_COUNT"); do
    VPN_USER="vpnuser$i"
    VPN_PASSWORD=$(openssl rand -hex 10)
    echo "$VPN_USER * \"$VPN_PASSWORD\" *" >> /etc/ppp/chap-secrets
    USER_LIST+="  Пользователь $i — логин: $VPN_USER  пароль: $VPN_PASSWORD\n"
done

# -----------------------------------------------------------------------------
# Включение IP Forwarding
# -----------------------------------------------------------------------------

cat > /etc/sysctl.d/60-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
EOF
sysctl -q -p /etc/sysctl.d/60-vpn.conf

# -----------------------------------------------------------------------------
# Настройка firewall (iptables)
# UDP 1701 принимается только через IPsec-туннель — это правильно с точки зрения
# безопасности: L2TP-порт не торчит наружу открытым.
# -----------------------------------------------------------------------------

# Сбрасываем старые правила только в нужных цепочках, не трогая остальные
iptables -t nat -D POSTROUTING -s "$VPN_SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true
iptables -D INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p esp -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p udp -m policy --dir in --pol ipsec -m udp --dport 1701 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$DEFAULT_IFACE" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i ppp+ -o "$DEFAULT_IFACE" -j ACCEPT 2>/dev/null || true

# Добавляем актуальные правила
iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$DEFAULT_IFACE" -j MASQUERADE
iptables -A INPUT -p udp --dport 500  -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT
iptables -A INPUT -p esp              -j ACCEPT
# L2TP (1701) принимаем только из IPsec-туннеля
iptables -A INPUT -p udp -m policy --dir in --pol ipsec -m udp --dport 1701 -j ACCEPT
iptables -A FORWARD -i "$DEFAULT_IFACE" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ppp+ -o "$DEFAULT_IFACE" -j ACCEPT

# Сохраняем правила
netfilter-persistent save

# -----------------------------------------------------------------------------
# Запуск и включение сервисов
# -----------------------------------------------------------------------------

systemctl restart strongswan-starter
systemctl restart xl2tpd
systemctl enable strongswan-starter xl2tpd

# Проверяем, что сервисы поднялись
sleep 2
for SVC in strongswan-starter xl2tpd; do
    if ! systemctl is-active --quiet "$SVC"; then
        echo "Предупреждение: сервис $SVC не запустился. Проверьте: journalctl -u $SVC" >&2
    fi
done

# -----------------------------------------------------------------------------
# Сохранение и вывод информации
# -----------------------------------------------------------------------------

INFO_FILE="/root/vpn-info.txt"
cat > "$INFO_FILE" <<EOF
==============================================
      L2TP/IPsec VPN — данные подключения
==============================================

Сервер:             $EXTERNAL_IP
IPsec Pre-Shared Key: $PSK_KEY

Учётные записи:
$(echo -e "$USER_LIST")
Настройка клиента:
  Тип VPN:     L2TP/IPsec с общим ключом (PSK)
  Сервер:      $EXTERNAL_IP
  Ключ PSK:    $PSK_KEY
  Логин/пароль: см. выше

Открытые порты (UDP): 500, 4500, ESP (протокол 50)
Порт 1701 не открыт напрямую — принимается только через IPsec.

Windows: если не подключается — добавьте в реестр:
  HKLM\System\CurrentControlSet\Services\Rasman\Parameters
  DWORD: NegotiateDH2048_AES256 = 1
==============================================
EOF
chmod 600 "$INFO_FILE"

echo ""
echo "=============================================="
echo "  L2TP/IPsec VPN сервер успешно настроен!"
echo "=============================================="
echo "  Сервер:  $EXTERNAL_IP"
echo "  PSK:     $PSK_KEY"
echo ""
echo "  Учётные записи:"
echo -e "$USER_LIST"
echo "  Подробности сохранены в: $INFO_FILE"
echo "=============================================="
