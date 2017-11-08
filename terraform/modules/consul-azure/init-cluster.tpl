#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log) 2>&1

# Set local/private IP address
local_ipv4="$(echo -e `hostname -I` | tr -d '[:space:]')"

# Detect package management system.
YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)



#######################
# Install Prerequisites
#######################
echo "Installing jq"
sudo curl --silent -Lo /bin/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
sudo chmod +x /bin/jq

echo "Setting timezone to UTC"
sudo timedatectl set-timezone UTC

if [[ ! -z $${YUM} ]]; then
  echo "RHEL/CentOS system detected"
  echo "Performing updates and installing prerequisites"
  sudo yum-config-manager --enable rhui-REGION-rhel-server-releases-optional
  sudo yum-config-manager --enable rhui-REGION-rhel-server-supplementary

  sudo yum -y check-update
  sudo yum install -q -y wget unzip bind-utils ntp
  sudo systemctl start ntpd.service
  sudo systemctl enable ntpd.service
  sudo yum install -q -y gcc libffi-devel python-devel openssl-devel python-pip
  sudo pip install azure-cli
elif [[ ! -z $${APT_GET} ]]; then
  echo "Debian/Ubuntu system detected"
  echo "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y wget unzip dnsutils ntp
  sudo systemctl start ntp.service
  sudo systemctl enable ntp.service
  sudo apt-get install -qq -y libssl-dev libffi-dev python-dev build-essential python-pip
  sudo pip install azure-cli
else
  echo "Prerequisites not installed due to OS detection failure"
  exit 1;
fi

echo "Disable reverse dns lookup in SSH"
sudo sh -c 'echo "\nUseDNS no" >> /etc/ssh/sshd_config'

echo "Completed Installing Prerequisites"



####################
# Set up Consul User
####################
USER="consul"
COMMENT="Consul"
GROUP="consul"
HOME="/srv/consul"

echo "Creating Consul user"
user_rhel() {
  # RHEL user setup
  sudo /usr/sbin/groupadd --force --system $${GROUP}

  if ! getent passwd $${USER} >/dev/null ; then
    sudo /usr/sbin/adduser \
      --system \
      --gid $${GROUP} \
      --home $${HOME} \
      --no-create-home \
      --comment "$${COMMENT}" \
      --shell /bin/false \
      $${USER}  >/dev/null
  fi
}

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $${GROUP} >/dev/null
  then
    sudo addgroup --system $${GROUP} >/dev/null
  fi

  if ! getent passwd $${USER} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $${GROUP} \
      --home $${HOME} \
      --no-create-home \
      --gecos "$${COMMENT}" \
      --shell /bin/false \
      $${USER}  >/dev/null
  fi
}

if [[ ! -z $${YUM} ]]; then
  echo "Setting up user $${USER} for RHEL/CentOS"
  user_rhel
elif [[ ! -z $${APT_GET} ]]; then
  echo "Setting up user $${USER} for Debian/Ubuntu"
  user_ubuntu
else
  echo "$${USER} user not created due to OS detection failure"
  exit 1;
fi



###############################
# Install and Configure Dnsmasq
###############################
if [[ ! -z $${YUM} ]]; then
  echo "Installing dnsmasq"
  sudo yum install -q -y dnsmasq
elif [[ ! -z $${APT_GET} ]]; then
  echo "Installing dnsmasq"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y dnsmasq-base dnsmasq
else
  echo "Dnsmasq not installed due to OS detection failure"
  exit 1;
fi

echo "Configuring dnsmasq to forward .consul requests to consul port 8600"
sudo sh -c 'echo "server=/consul/127.0.0.1#8600" >> /etc/dnsmasq.d/consul'

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq



##############################
# Install and Configure Consul
##############################
CONSUL_VERSION="${consul_version}"
CONSUL_ZIP="consul_$${CONSUL_VERSION}_linux_amd64.zip"
CONSUL_URL="https://releases.hashicorp.com/consul/$${CONSUL_VERSION}/$${CONSUL_ZIP}"

echo "Downloading consul $${CONSUL_VERSION}"
curl --silent --output /tmp/$${CONSUL_ZIP} $${CONSUL_URL}

logger "Installing consul"
sudo unzip -o /tmp/$${CONSUL_ZIP} -d /usr/local/bin/
sudo chmod 0755 /usr/local/bin/consul
sudo chown consul:consul /usr/local/bin/consul
sudo mkdir -pm 0755 /etc/consul.d
sudo mkdir -pm 0755 /opt/consul/data
sudo chown consul:consul /opt/consul/data

echo "/usr/local/bin/consul --version: $(/usr/local/bin/consul --version)"

# Write base client Consul config
sudo tee /etc/consul.d/consul-default.json <<EOF
{
  "advertise_addr": "$${local_ipv4}",
  "data_dir": "/opt/consul/data",
  "client_addr": "0.0.0.0",
  "log_level": "INFO",
  "ui": true,
  "retry_join": ["provider=azure tag_name=consul_datacenter tag_value=${consul_datacenter} subscription_id=${auto_join_subscription_id} tenant_id=${auto_join_tenant_id} client_id=${auto_join_client_id} secret_access_key=${auto_join_secret_access_key}"]
}
EOF

# Loop through Consul datacenter tags for WAN join
tags=( ${consul_join_wan} )
for tag in "$${tags[@]}"
do
    echo $i
    jq ".retry_join_wan += [\"provider=azure tag_name=consul_datacenter tag_value=$tag subscription_id=${auto_join_subscription_id} tenant_id=${auto_join_tenant_id} client_id=${auto_join_client_id} secret_access_key=${auto_join_secret_access_key}\"]" /etc/consul.d/consul-default.json > /tmp/consul-default.json.tmp
    sudo mv /tmp/consul-default.json.tmp /etc/consul.d/consul-default.json
done

# Write base server Consul config
sudo tee /etc/consul.d/consul-server.json <<EOF
{
  "server": true,
  "bootstrap_expect": ${cluster_size}
}
EOF



###############################
# Create Consul Systemd Service
###############################
sudo mkdir -p /tmp/consul/init/systemd/
sudo tee /tmp/consul/init/systemd/consul.service <<'EOF'
[Unit]
Description=Consul Agent
Requires=network-online.target
After=network-online.target

[Service]
Restart=on-failure
ExecStart=/usr/local/bin/consul agent -config-dir /etc/consul.d
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=consul
Group=consul

[Install]
WantedBy=multi-user.target
EOF

if [[ ! -z $${YUM} ]]; then
  SYSTEMD_DIR="/etc/systemd/system"
  echo "Installing Consul systemd service for RHEL/CentOS"
  sudo cp /tmp/consul/init/systemd/consul.service $${SYSTEMD_DIR}
  sudo chmod 0664 $${SYSTEMD_DIR}/consul.service
elif [[ ! -z $${APT_GET} ]]; then
  SYSTEMD_DIR="/lib/systemd/system"
  echo "Installing Consul systemd service for Debian/Ubuntu"
  sudo cp /tmp/consul/init/systemd/consul.service $${SYSTEMD_DIR}
  sudo chmod 0664 $${SYSTEMD_DIR}/consul.service
else
  echo "Service not installed due to OS detection failure"
  exit 1;
fi

sudo systemctl enable consul
sudo systemctl start consul

echo "Completed Configuration of Consul Node. Run 'consul members' to view cluster information."

