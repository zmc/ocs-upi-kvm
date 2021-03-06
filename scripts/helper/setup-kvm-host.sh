#!/bin/bash

# There are no input arguments.  This script sets up a kvm libvirt host
# server supporting an openshift clusters running in VMs.  This script
# installs the virtualization stack, configures firewall, iptables, dns
# overlays, and haproxy.  This setup assumes the IP addresses that are
# generated by the helpernode playbook.  These values are hardcoded 
# along with the cluster domain, so if the underlying projects change
# this script will have to change as well.

set -xe

TOP_DIR=$(pwd)/..

if [ ! -e $TOP_DIR/files/haproxy.cfg ]; then
	echo "Please invoke from the directory ocs-upi-kvm/scripts"
	exit 1
fi

source helper/parameters.sh

# These parameters are tied to GH project ocp4-upi-kvm

CLUSTER_CIDR=${CLUSTER_CIDR:="192.168.88.0/24"}
CLUSTER_GATEWAY=${CLUSTER_GATEWAY:="192.168.88.1"}

yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
yum -y install powerpc-utils net-tools wget git patch gcc-c++ make
yum -y module install virt container-tools
yum -y install libvirt-devel libguestfs libguestfs-tools virt-install ansible haproxy tmux

pushd ~
if [ ! -e wipe-2.3.1-17.15.ppc64le.rpm ]; then
	wget http://rpmfind.net/linux/opensuse/ports/ppc/tumbleweed/repo/oss/ppc64le/wipe-2.3.1-17.15.ppc64le.rpm
fi
yum -y localinstall wipe-2.3.1-17.15.ppc64le.rpm
popd

# Enable IP Forwarding

sysctl net.ipv4.ip_forward
sysctl net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

# Enable TCP access for libvirtd

sed -i 's/#LIBVIRTD_ARGS=\"--listen\"/LIBVIRTD_ARGS=\"--listen\"/' /etc/sysconfig/libvirtd
sed -i 's/#listen_tls = 0/listen_tls = 0/' /etc/libvirt/libvirtd.conf
sed -i 's/#listen_tcp = 1/listen_tcp = 1/' /etc/libvirt/libvirtd.conf
sed -i 's/#auth_tcp = "sasl"/auth_tcp = "none"/' /etc/libvirt/libvirtd.conf
sed -i 's/#tcp_port = "16509"/tcp_port = "16509"/' /etc/libvirt/libvirtd.conf

systemctl restart libvirtd

# Allow connections to the libvirt daemon from the IP range used by the cluster

iptables -I INPUT -p tcp -s $CLUSTER_CIDR -d 192.168.122.1 --dport 16509 -j ACCEPT -m comment --comment "Allow insecure libvirt clients"

# This is being deprecated and produces warning messages

sed -i 's/AllowZoneDrifting=yes/AllowZoneDrifting=no/' /etc/firewalld/firewalld.conf

firewall-cmd --zone=public --add-port=623/udp      --permanent	# Remote Management and Control Protocol (ipmi / bmc)
firewall-cmd --zone=public --add-port=80/tcp       --permanent  # HAProxy
firewall-cmd --zone=public --add-port=443/tcp      --permanent  # HAProxy
firewall-cmd --zone=public --add-port=6443/tcp     --permanent  # HAProxy
firewall-cmd --zone=public --add-port=22623/tcp    --permanent  # HAProxy

firewall-cmd --zone=libvirt --add-service=libvirt  --permanent
firewall-cmd --zone=libvirt --add-service=http     --permanent
firewall-cmd --zone=libvirt --add-service=https    --permanent
firewall-cmd --zone=libvirt --add-port=623/udp     --permanent	# RMCP (ipmi / bmc)

firewall-cmd --reload

# Setup the DNS overlay for the cluster

echo -e "[main]\ndns=dnsmasq" | tee /etc/NetworkManager/conf.d/openshift.conf
echo server=/$CLUSTER_DOMAIN/$CLUSTER_GATEWAY | tee /etc/NetworkManager/dnsmasq.d/openshift.conf

systemctl restart NetworkManager
systemctl restart firewalld
systemctl restart libvirtd

set +e

# Setup HAProxy

cat > /etc/firewalld/services/haproxy-http.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
<short>HAProxy-HTTP</short>
<description>HAProxy load-balancer</description>
<port protocol="tcp" port="80"/>
</service>
EOF

chmod 640 /etc/firewalld/services/haproxy-http.xml
restorecon /etc/firewalld/services/haproxy-http.xml

cat > /etc/firewalld/services/haproxy-https.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
<short>HAProxy-HTTPS</short>
<description>HAProxy load-balancer</description>
<port protocol="tcp" port="443"/>
</service>
EOF

chmod 640 /etc/firewalld/services/haproxy-https.xml
restorecon /etc/firewalld/services/haproxy-https.xml

if [ ! -e /etc/haproxy/haproxy.cfg.orig ]; then
	cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
fi
cp $TOP_DIR/files/haproxy.cfg /etc/haproxy/haproxy.cfg

chmod 644 /etc/haproxy/haproxy.cfg
restorecon -Rv /etc/haproxy

semanage port -ln | grep 6443
if [ "$?" != "0" ]; then
	semanage port -a -t openshift_port_t -p tcp 6443
fi
semanage port -ln | grep 22623
if [ "$?" != "0" ]; then
	semanage port -a -t openshift_port_t -p tcp 22623
fi
setsebool -P haproxy_connect_any=1

systemctl enable haproxy
systemctl start haproxy
