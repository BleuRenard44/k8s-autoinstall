#!/bin/bash

set -e

DD_API_KEY="2583d387f416c4c033b369098cf76548"
DD_SITE="datadoghq.eu"

echo "Installation Kubernetes + Autoscale + Datadog Operator..."

# 1. Mise à jour système
sudo apt update && sudo apt upgrade -y

# 2. Désactiver le swap
sudo dphys-swapfile swapoff || true
sudo dphys-swapfile uninstall || true
sudo systemctl disable dphys-swapfile || true
sudo swapoff -a

# 3. Bridge networking
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system

# 4. Installer containerd
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 5. Installer Kubernetes (kubelet, kubeadm, kubectl)
sudo apt install -y apt-transport-https ca-certificates curl
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://pkgs.k8s.io/core:/stable:/deb/Release.key
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 6. Initialiser Kubernetes
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# 7. Configurer kubectl
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 8. Installer Flannel (réseau)
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 9. Autoriser les pods sur le master
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# 10. Installer Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
sleep 10
kubectl patch deployment metrics-server -n kube-system \
  --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# 11. Déployer une app avec autoscale
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-stress-app
spec:
  replicas: 4
  selector:
    matchLabels:
      app: cpu-stress
  template:
    metadata:
      labels:
        app: cpu-stress
    spec:
      containers:
      - name: stress
        image: vish/stress
        args: ["-cpus", "1"]
        resources:
          requests:
            cpu: "100m"
          limits:
            cpu: "500m"
EOF

kubectl autoscale deployment cpu-stress-app \
  --cpu-percent=50 --min=4 --max=10

# 12. Installer l’opérateur Datadog
kubectl apply -f https://github.com/DataDog/datadog-operator/releases/latest/download/datadog-operator.yaml

# 13. Créer le secret Datadog API Key
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY

# 14. Déployer la ressource DatadogAgent
cat <<EOF | kubectl apply -f -
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
spec:
  global:
    site: "$DD_SITE"
    credentials:
      apiSecret:
        secretName: "datadog-secret"
        keyName: "api-key"
    tags:
      - "env:dev"
  features:
    apm:
      instrumentation:
        enabled: true
        targets:
          - name: "default-target"
            ddTraceVersions:
              java: "1"
              python: "3"
              js: "5"
              php: "1"
              dotnet: "3"
    logCollection:
      enabled: true
      containerCollectAll: true
EOF

echo "Installation terminée !"
echo ""
echo "Vérifiez dans quelques minutes : https://app.datadoghq.eu/infrastructure"
echo "Test HPA : kubectl get hpa"
echo "Monitoring + Logs + APM sont maintenant actifs via l'opérateur Datadog"
