#!/bin/bash

dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $dir
source "$dir/config"
MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
mkdir -p $dir/networks
mkdir -p $dir/config-drives/$VM1_NAME-config
mkdir -p $dir/config-drives/$VM2_NAME-config
mkdir -p $(dirname "$VM1_HDD")
mkdir -p $(dirname "$VM2_HDD")

############################ NETWORKS ################################
#External
echo "
<network>
  <name>$EXTERNAL_NET_NAME</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='$EXTERNAL_NET_HOST_IP' netmask='$EXTERNAL_NET_MASK'>
    <dhcp>
      <range start='$EXTERNAL_NET.2' end='$EXTERNAL_NET.254'/>
      <host mac='$MAC' name='$VM1_NAME' ip='$VM1_EXTERNAL_IP'/>
    </dhcp>
  </ip>
</network>" > networks/$EXTERNAL_NET_NAME.xml


#Inaternal
echo "
<network>
  <name>$INTERNAL_NET_NAME</name>
</network>" > $dir/networks/$INTERNAL_NET_NAME.xml

#Management
echo "
<network>
  <name>$MANAGEMENT_NET_NAME</name>
  <ip address='$MANAGEMENT_HOST_IP' netmask='$MANAGEMENT_NET_MASK'/>
</network>" > $dir/networks/$MANAGEMENT_NET_NAME.xml


virsh net-destroy default
virsh net-undefine default
virsh net-define $dir/networks/$EXTERNAL_NET_NAME.xml
virsh net-start $EXTERNAL_NET_NAME
virsh net-autostart $EXTERNAL_NET_NAME
virsh net-define $dir/networks/$INTERNAL_NET_NAME.xml
virsh net-start $INTERNAL_NET_NAME
virsh net-autostart $INTERNAL_NET_NAME
virsh net-define $dir/networks/$MANAGEMENT_NET_NAME.xml
virsh net-start $MANAGEMENT_NET_NAME
virsh net-autostart $MANAGEMENT_NET_NAME

##################################################################################

IMG_DESTINATION="/var/lib/libvirt/images/ubunut-server-16.04.qcow2"
#IMG_SOURCE_URL="https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img"
wget -O "$IMG_DESTINATION" "$VM_BASE_IMAGE"

################ Claud init ###############
################ VM1 Files ################
echo "
[ req ]
default_bits                = 4096
default_keyfile             = privkey.pem
distinguished_name          = req_distinguished_name
req_extensions              = v3_req

[ req_distinguished_name ]
countryName                 = Country Name (2 letter code)
countryName_default         = UK
stateOrProvinceName         = State or Province Name (full name)
stateOrProvinceName_default = Wales
localityName                = Locality Name (eg, city)
localityName_default        = Cardiff
organizationName            = Organization Name (eg, company)
organizationName_default    = Example UK
commonName                  = Common Name (eg, YOUR name)
commonName_default          = one.test.app.example.net
commonName_max              = 64

[ v3_req ]
basicConstraints            = CA:FALSE
keyUsage                    = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName              = @alt_names

[alt_names]
IP.1  = $VM1_EXTERNAL_IP
DNS.1 = $VM1_NAME" > config-drives/$VM1_NAME-config/openssl-san.cnf

echo "
server {
listen  $NGINX_PORT;
ssl on;
ssl_certificate /etc/ssl/certs/web.crt;
ssl_certificate_key /etc/ssl/certs/web.key;
 location / {
            proxy_pass http://$VM2_VXLAN_IP:$APACHE_PORT;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
    }
} " >> config-drives/$VM1_NAME-config/nginx.conf

################# YML CONFIG ##################################

echo "version: '2'
services:
  nginx:
    image: $NGINX_IMAGE
    ports:
      - '$NGINX_PORT:$NGINX_PORT'
    volumes:
      - /opt/etc/nginx/nginx.conf:/etc/nginx/conf.d/default.conf
      - $NGINX_LOG_DIR:/var/log/nginx
      - /etc/ssl/certs:/etc/ssl/certs" > config-drives/$VM1_NAME-config/docker-compose.yml



################# VM2 FILE #################################

echo "version: '2'
services:
  apache:
    image: $APACHE_IMAGE
    ports:
      - '$VM2_VXLAN_IP:$APACHE_PORT:80' " >> config-drives/$VM2_NAME-config/docker-compose.yml

###### vm1 user-data ######
cat << EOF > config-drives/$VM1_NAME-config/user-data
#cloud-config
ssh_authorized_keys:
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - software-properties-common
runcmd:
  - echo 1 > /proc/sys/net/ipv4/ip_forward
  - iptables -A INPUT -i lo -j ACCEPT
  - iptables -A FORWARD -i $VM1_EXTERNAL_IF -o $VM1_INTERNAL_IF -j ACCEPT
  - iptables -t nat -A POSTROUTING -o $VM1_EXTERNAL_IF -j MASQUERADE
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM2_INTERNAL_IP local $VM1_INTERNAL_IP dstport 4789
  - ip addr add $VM1_VXLAN_IP/24 dev vxlan0
  - ip link set vxlan0 up
  - apt-get update
  - apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  - apt-get update && apt-get install -y docker-ce docker-compose
  - mount -t iso9660 -o ro /dev/sr0 /mnt
  - mkdir -p /opt/etc/nginx
  - mkdir -p /opt/etc/docker
  - cp /mnt/openssl-san.cnf /usr/lib/ssl/openssl-san.cnf
  - openssl genrsa -out /etc/ssl/certs/root-ca.key 4096
  - openssl req -x509 -new -key /etc/ssl/certs/root-ca.key -days 365 -out /etc/ssl/certs/root-ca.crt -subj "/C=UA/L=Kharkov/O=HOME/OU=IT/CN=$VM1_NAME"
  - openssl genrsa -out /etc/ssl/certs/web.key 4096
  - openssl req -new -key /etc/ssl/certs/web.key -out /etc/ssl/certs/web.csr -config /usr/lib/ssl/openssl-san.cnf -subj "/C=UA/L=Kharkov/O=HOME/OU=IT/CN=$VM1_NAME"
  - openssl x509 -req -in /etc/ssl/certs/web.csr -CA /etc/ssl/certs/root-ca.crt  -CAkey /etc/ssl/certs/root-ca.key -CAcreateserial -out /etc/ssl/certs/web.crt -days 365 -extensions v3_req -extfile /usr/lib/ssl/openssl-san.cnf
  - cat /etc/ssl/certs/root-ca.crt >> /etc/ssl/certs/web.crt
  - cp /mnt/nginx.conf /opt/etc/nginx/nginx.conf
  - cp /mnt/docker-compose.yml /opt/etc/docker/docker-compose.yml
  - cd /opt/etc/docker
  - docker-compose up -d
EOF

###### vm2 user-data ######
cat << EOF > config-drives/$VM2_NAME-config/user-data
#cloud-config
ssh_authorized_keys:
  - $(cat  $SSH_PUB_KEY)
apt_update: true
apt_sources:
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - software-properties-common
runcmd:
  - ip link add $VXLAN_IF type vxlan id $VID remote $VM1_INTERNAL_IP local $VM2_INTERNAL_IP dstport 4789
  - ip link set vxlan0 up
  - ip addr add $VM2_VXLAN_IP/24 dev vxlan0
  - apt-get update
  - apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  - apt-get update && apt-get install -y docker-ce docker-compose
  - mount -t iso9660 -o ro /dev/sr0 /mnt
  - mkdir -p /opt/etc/docker
  - cp /mnt/docker-compose.yml /opt/etc/docker/docker-compose.yml
  - cd /opt/etc/docker
  - docker-compose up -d
EOF

###### vm1 meta-data ######
echo "hostname: $VM1_NAME
local-hostname: $VM1_NAME
network-interfaces: |
  auto $VM1_EXTERNAL_IF
  iface $VM1_EXTERNAL_IF inet dhcp
  dns-nameservers $VM_DNS

  auto $VM1_INTERNAL_IF
  iface $VM1_INTERNAL_IF inet static
  address $VM1_INTERNAL_IP
  netmask $INTERNAL_NET_MASK

  auto $VM1_MANAGEMENT_IF
  iface $VM1_MANAGEMENT_IF inet static
  address $VM1_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM1_NAME-config/meta-data

###### vm2 meta-data ######
echo "hostname: $VM2_NAME
local-hostname: $VM2_NAME
network-interfaces: |

  auto $VM2_INTERNAL_IF
  iface $VM2_INTERNAL_IF inet static
  address $VM2_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  gateway $VM1_INTERNAL_IP
  dns-nameservers $EXTERNAL_NET_HOST_IP $VM_DNS

  auto $VM2_MANAGEMENT_IF
  iface $VM2_MANAGEMENT_IF inet static
  address $VM2_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK" > config-drives/$VM2_NAME-config/meta-data

###### create ISO ######
mkisofs -o $VM1_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM1_NAME-config
mkisofs -o $VM2_CONFIG_ISO -V cidata -r -J --quiet config-drives/$VM2_NAME-config

##################################################################################

echo "Create VM1.xml and VM2.xml"

echo "<domain type='kvm'>
  <name>vm1</name>
  <memory unit='MiB'>$VM1_MB_RAM</memory>
  <vcpu placement='static'>$VM1_NUM_CPU</vcpu>
  <os>
    <type>$VM_TYPE</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$VM1_HDD'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$VM1_CONFIG_ISO'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <mac address='$MAC'/>
      <source network='$EXTERNAL_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <interface type='network'>
      <source network='$INTERNAL_NET_NAME'/>
      <model type='virtio'/>
      <protocol family='ipv4'>
      <ip address='192.168.124.101' prefix='24'/>
      <route gateway='192.168.124.1'/>
      </protocol>
    </interface>
    <interface type='network'>
      <source network='$MANAGEMENT_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <source path='/dev/pts/0'/>
      <target port='0'/>
    </serial>
    <console type='pty' tty='/dev/pts/0'>
      <source path='/dev/pts/0'/>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes'/>
  </devices>
  <features>
    <acpi/>
  </features>
</domain>" > $dir/vm1.xml


echo "<domain type='kvm'>
  <name>$VM2_NAME</name>
  <memory unit='MiB'>$VM2_MB_RAM</memory>
  <vcpu placement='static'>$VM2_NUM_CPU</vcpu>
  <os>
    <type>$VM_TYPE</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$VM2_HDD'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$VM2_CONFIG_ISO'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$INTERNAL_NET_NAME'/>
      <model type='virtio'/>
        <protocol family='ipv4'>
        <ip address='192.168.124.102' prefix='24'/>
        <route gateway='192.168.124.1'/>
        </protocol>
    </interface>
    <interface type='network'>
      <source network='$MANAGEMENT_NET_NAME'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <source path='/dev/pts/0'/>
      <target port='0'/>
    </serial>
    <console type='pty' tty='/dev/pts/0'>
      <source path='/dev/pts/0'/>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes'/>
  </devices>


</domain>" > $dir/vm2.xml

echo "start VM1"
cp $IMG_DESTINATION $VM1_HDD
virsh define vm1.xml
virsh start vm1

sleep 300

echo "start VM2"

cp $IMG_DESTINATION $VM2_HDD

virsh define vm2.xml
virsh start vm2



