#!/usr/bin/env bash
################################################################################
# This is property of eXtremeSHOK.com
# You are free to use, modify and distribute, however you may not remove this notice.
# Copyright (c) Adrian Jon Kriel :: admin@extremeshok.com
################################################################################
#
# Script updates can be found at: https://github.com/extremeshok/xshok-proxmox
#
# tinc vpn - installation script for Proxmox, Debian, CentOS and RedHat based servers
#
# License: BSD (Berkeley Software Distribution)
#
# Usage:
# curl -O https://raw.githubusercontent.com/extremeshok/xshok-proxmox/master/networking/tincvpn.sh && chmod +x tincvpn.sh
# ./tincvpn.sh -h
#
# Example for 3 node Cluster
#
# cat /etc/hosts
# global ips for tinc servers
# 11.11.11.11 host1
# 22.22.22.22 host2
# 33.33.33.33 host3
#
# First Host (hostname: host1)
# ./tincvpn.sh -i 1 -c host2
# Second Host (hostname: host2)
# ./tincvpn.sh -i 2 -c host3
# Third Host (hostname: host3)
# ./tincvpn.sh -3 -c host1
#
#
################################################################################
#
#    THERE ARE  USER CONFIGURABLE OPTIONS IN THIS SCRIPT
#   ALL CONFIGURATION OPTIONS ARE LOCATED BELOW THIS MESSAGE
#
##############################################################
vpn_ip_last=1
vpn_connect_to=""
vpn_port=655
my_default_v4ip=$(ip -4 route get 8.8.8.8 | grep -oP 'src \K\S+')
#my_default_v4ip=""
reset="no"

while getopts i:p:c:a:rh:uh option
do
  case "${option}"
      in
    i) vpn_ip_last=${OPTARG} ;;
    p) vpn_port=${OPTARG} ;;
    c) vpn_connect_to=${OPTARG} ;;
    a) my_default_v4ip=${OPTARG} ;;
    r) reset="yes" ;;
    u) uninstall="yes" ;;
    *) echo "-i <last_ip_part 10.10.1.?> -p <vpn port if not 655> -c <vpn host to connect to, eg. prx_b> -a <public ip address, or will auto-detect> -r (reset) -u (uninstall)" ; exit ;;
  esac
done

if [ "$reset" == "yes" ] || [ "$uninstall" == "yes" ] ; then
  echo "Stopping Tinc"
  systemctl stop tinc-xsvpn.service || true
  pkill -9 tincd || true

  echo "Removing configs"
  rm -rf /etc/tinc/xsvpn
  mv -f /etc/tinc/nets.boot.orig /etc/tinc/nets.boot || true
  rm -f /etc/network/interfaces.d/tinc-vpn.cfg
  rm -f /etc/systemd/system/tinc-xsvpn.service

  if [ "$uninstall" == "yes" ] ; then
    systemctl disable tinc-xsvpn.service || true
    apt-get remove -y tinc || true
    echo "Tinc uninstalled"
    exit 0
  fi
fi

# Install tinc if not installed
if ! command -v tincd &> /dev/null; then
  echo "Installing Tinc..."
  apt-get install -y tinc || { echo "Failed to install tinc"; exit 1; }
fi

# Default IP detection
if [ -z "$my_default_v4ip" ]; then
  my_default_v4ip=$(ip -4 route get 8.8.8.8 | grep -oP 'src \K\S+')
  if [ -z "$my_default_v4ip" ]; then
    echo "ERROR: Could not detect default IPv4 address"
    exit 1
  fi
fi

# Configuring VPN
my_name=$(uname -n)
my_name=${my_name//-/_}

if [[ "$vpn_connect_to" =~ "-" ]]; then
  echo "ERROR: '-' character is not allowed in vpn_connect_to"
  exit 1
fi

# Generate and configure Tinc VPN
echo "VPN IP: 10.10.1.${vpn_ip_last}"
echo "VPN PORT: ${vpn_port}"
echo "VPN Connect to host: ${vpn_connect_to}"
echo "Public Address: ${my_default_v4ip}"

mkdir -p /etc/tinc/xsvpn/hosts
tincd -K4096 -c /etc/tinc/xsvpn </dev/null 2>/dev/null || { echo "Failed to generate RSA keys"; exit 1; }

# Create tinc.conf
cat <<EOF > /etc/tinc/xsvpn/tinc.conf
Name = $my_name
AddressFamily = ipv4
Interface = tun0
Mode = switch
ConnectTo = $vpn_connect_to
EOF

# Create host config
cat <<EOF > "/etc/tinc/xsvpn/hosts/$my_name"
Address = ${my_default_v4ip}
Subnet = 10.10.1.${vpn_ip_last}
Port = ${vpn_port}
Compression = 10
EOF
cat /etc/tinc/xsvpn/rsa_key.pub >> "/etc/tinc/xsvpn/hosts/${my_name}"

# Create tinc-up script
cat <<EOF > /etc/tinc/xsvpn/tinc-up
#!/usr/bin/env bash
ip link set \$INTERFACE up
ip addr add 10.10.1.${vpn_ip_last}/24 dev \$INTERFACE
ip route add 10.10.1.0/24 dev \$INTERFACE
ip route add -net 224.0.0.0 netmask 240.0.0.0 dev \$INTERFACE
EOF

chmod 755 /etc/tinc/xsvpn/tinc-up

# Create tinc-down script
cat <<EOF > /etc/tinc/xsvpn/tinc-down
#!/usr/bin/env bash
ip route del 10.10.1.0/24 dev \$INTERFACE
ip addr del 10.10.1.${vpn_ip_last}/24 dev \$INTERFACE
ip link set \$INTERFACE down
ip route del -net 224.0.0.0 netmask 240.0.0.0 dev \$INTERFACE
EOF

chmod 755 /etc/tinc/xsvpn/tinc-down

# Create systemd service
cat <<EOF > /etc/systemd/system/tinc-xsvpn.service
[Unit]
Description=Tinc VPN
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/tinc/xsvpn
ExecStart=$(command -v tincd) -n xsvpn -D -d2
ExecReload=$(command -v tincd) -n xsvpn -kHUP
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable tinc-xsvpn.service
systemctl start tinc-xsvpn.service || { echo "Failed to start Tinc VPN service"; exit 1; }

echo "Tinc VPN setup completed successfully."
