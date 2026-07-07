#!/bin/bash

if [ "$1" -eq 0 ]; then
ports=(6443 2379 2380 10250 10259 10257)

for port in "${ports[@]}"; do
	echo -n "Port $port: "
	nc 127.0.0.1 "$port" -zv -w 2 &>/dev/null
	if [ $? -eq 0 ]; then
		echo "$port est ouvert"
		exit 1
	else
		echo "$port est fermer"
	fi
done

swap_total=$(free | grep "Swap" | awk '{print $2}')
swap_swapon_res=$(swapon --show)
if [ "$swap_swapon_res" ]; then #or -ne 0 for swap_total
	echo "Swap is not disable"
	sudo swapoff -a
else
	echo "Swap is disable"
fi
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

lsmod | grep -E 'overlay|br_netfilter'

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system &>/dev/null

ipv4=$(sysctl net.ipv4.ip_forward | awk '{print $3}')

if [ "$ipv4" -ne 1 ]; then
	exit 1
else
	echo "ipv4 is setted to 1"
fi

sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)

if [ -f /etc/apt/sources.list.d/docker.list ]; then
	sudo rm /etc/apt/sources.list.d/docker.list
fi

# Add Docker's official GPG key:
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl status docker

elif [ "$1" -eq 1 ]; then
    sudo mv /etc/containerd/config.toml /etc/containerd/config.toml.bak 2>/dev/null
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

    toml=$(grep -c "SystemdCgroup" /etc/containerd/config.toml)
    systemcgroup=$(grep "SystemdCgroup" /etc/containerd/config.toml | awk '{print $3}')

    if [[ "$toml" -eq 1 && "$systemcgroup" = 'false' ]]; then
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi
    grep "SystemdCgroup" /etc/containerd/config.toml
    sudo systemctl restart containerd
fi

if [ "$1" -eq 2 ]; then

	sudo apt-get update
	sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
	sudo mkdir -p /etc/apt/keyrings
	if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
		curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key |\
			sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
		sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
	fi
	echo "Vérification réussie."
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' |\
	       	sudo tee /etc/apt/sources.list.d/kubernetes.list
	sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # helps tools such as command-not-found to work correctly
	sudo apt-get update
	sudo apt-get install -y kubectl kubeadm kubelet
	sudo apt-mark hold kubelet kubeadm kubectl
	sudo systemctl enable --now kubelet

	kubeadm version
	kubectl version --client
fi
if [ "$1" = 'init' ]; then
    if [ ! -f kubeadm-config.yaml ]; then
        kubeadm config print init-defaults > kubeadm-config.yaml
    fi
    ip=$(ip -4 a show enp0s1 | grep inet | awk '{print $2}' | cut -d/ -f1)

    sudo sed -i "s/advertiseAddress: 1.2.3.4/advertiseAddress: $ip/" kubeadm-config.yaml

    if ! grep -q "controlPlaneEndpoint" kubeadm-config.yaml; then
        sudo sed -i "/kind: ClusterConfiguration/a controlPlaneEndpoint: \"$ip:6443\"" kubeadm-config.yaml
    fi

    if ! grep -q "podSubnet" kubeadm-config.yaml; then
        sudo sed -i '\#networking:#a\  podSubnet: 10.244.0.0/16' kubeadm-config.yaml
    fi
    cat kubeadm-config.yaml
    kubeadm config validate --config=kubeadm-config.yaml
fi
