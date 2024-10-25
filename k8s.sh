#!/bin/bash

set -e

ROLE=$1         # Rôle : master ou worker
MASTER_INIT=$2  # init ou join
IPADDR="$3"     # VIP du master

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
    echo "Usage: $0 <master|worker> [init]"
    exit 1
fi

# Vérifier si l'adresse IP a été passée pour le rôle master et l'initialisation
if [[ "$ROLE" == "master" && "$MASTER_INIT" == "init" && -z "$IPADDR" ]]; then
    echo "Usage: $0 master init <IPADDR>"
    exit 1
fi



# Installer les dépendances nécessaires
sudo apt-get update
sudo apt-get install -y curl gnupg apt-transport-https ca-certificates

# Activer le trafic ponté iptables sur tous les nœuds
echo "Activating bridged traffic..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Désactiver le swap sur tous les nœuds
echo "Disabling swap..."
sudo swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

# Installer le runtime CRI-O sur tous les nœuds
echo "Installing CRI-O..."
cat <<EOF | sudo tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo sysctl --system

#VAR
export OS="Debian_12"
export VERSION_CRI="1.28"
export VERSION_KUB="1.31"
export VERSION_CALICO="3.28.2"

#export IPADDR="192.168.50.11"
export POD_CIDR="10.1.0.0/16"



# Install des autres composantes
cat <<EOF | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /
EOF

cat <<EOF | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$VERSION_CRI.list
deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$VERSION_CRI/$OS/ /
EOF

curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$VERSION_CRI/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -

sudo apt-get update
sudo apt-get install cri-o cri-o-runc cri-tools socat -y

sudo systemctl daemon-reload
sudo systemctl enable crio --now

# Installer Kubernetes
echo "Installing Kubernetes..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v$VERSION_KUB/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$VERSION_KUB/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl

sudo apt-mark hold kubelet kubeadm kubectl


# Mettre a jour le hostname pour faciliter l'emplacement du master principal pour tous les noeuds
    echo " Update /etc/hosts file"
cat >>/etc/hosts<<EOF
$IPADDR kubernetesmaster1 master
EOF

# Configuration spécifique pour le nœud master principal
if [[ "$ROLE" == "master" && "$MASTER_INIT" == "init" ]]; then
    echo "Initializing Kubernetes primary master node..."
    sudo apt-get install -y jq
    cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$IPADDR
EOF

    # Résoudre l'incohérence de l'image "pause"
    sudo kubeadm config images pull


    # Initialisation du cluster sur le master principal
    sudo kubeadm init \
    --control-plane-endpoint "$IPADDR:6443" \
    --upload-certs \
    --apiserver-advertise-address="$IPADDR" \
    --apiserver-cert-extra-sans="$IPADDR" \
    --pod-network-cidr="$POD_CIDR" \
    --ignore-preflight-errors=Swap \
    --v=5

    # Configuration de kubectl pour l'utilisateur actuel
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    # Installation du réseau de pods Calico
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v$VERSION_CALICO/manifests/calico.yaml

    #Creer dossier pour le generation des scripts
    mkdir /vagrant/generate/
    
    # Génération du token et sauvegarde de la commande join pour les workers
    echo "Génération du token et récupération de la commande kubeadm join..."
    kubeadm token create --print-join-command > /vagrant/generate/kubeadm_join_worker.sh

    # Génération de la clé de certificat pour les autres nœuds master
    certificate_key=$(kubeadm init phase upload-certs --upload-certs | tail -n 1)
    echo "kubeadm join $IPADDR:6443 --token <token> --discovery-token-ca-cert-hash <hash> --control-plane --certificate-key $certificate_key" > /vagrant/generate/kubeadm_join_master.sh

    echo "La commande kubeadm join a été sauvegardée dans /vagrant/generate/kubeadm_join_worker.sh pour les workers et /vagrant/generate/kubeadm_join_master.sh pour les masters."

# Configuration pour l'ajout d'un second master
elif [[ "$ROLE" == "master" && "$MASTER_INIT" == "join" ]]; then
    echo "Joining the cluster as a secondary master node..."
    if [ -f /vagrant/generate/kubeadm_join_master.sh ]; then
        echo "Rejoindre le cluster en tant que nœud master..."
        # Rendre le script exécutable et l'exécuter
        chmod +x /vagrant/generate/kubeadm_join_master.sh
        /vagrant/generate/kubeadm_join_master.sh
    else
        echo "Le fichier /vagrant/generate/kubeadm_join_master.sh n'a pas été trouvé."
        echo "Veuillez exécuter la commande kubeadm join fournie par le nœud master principal pour ajouter ce nœud en tant que master."
    fi

# Configuration pour l'ajout d'un worker
else
    echo "Joining the cluster as a worker node..."
    if [ -f /vagrant/generate/kubeadm_join_worker.sh ]; then
        echo "Rejoindre le cluster en tant que nœud worker..."
        # Rendre le script exécutable et l'exécuter
        chmod +x /vagrant/generate/kubeadm_join_worker.sh
        /vagrant/generate/kubeadm_join_worker.sh
    else
        echo "Le fichier /vagrant/generate/kubeadm_join_worker.sh n'a pas été trouvé."
        echo "Veuillez exécuter la commande kubeadm join fournie par le nœud master pour ajouter ce nœud en tant que worker."
    fi
fi

echo "Installation complète ! apres lancer rook pour installer le stockage !!!"