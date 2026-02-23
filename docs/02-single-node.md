# Single-Node Kubernetes Cluster

One VM runs the entire Kubernetes control plane (etcd, kube-apiserver, kube-controller-manager,
kube-scheduler) plus worker components (containerd, kubelet, kube-proxy). This is ideal for
learning and experimentation.

---

## 1. Provision the VM

```bash
cd terraform/single-node
export TF_VAR_key_pair_name="my-key"   # your OpenStack keypair name

terraform init
terraform apply
```

Export the node IP for use throughout this guide:

```bash
export NODE_IP=$(terraform output -raw node_ip)
export NODE_NAME="k8s-node"
echo "Node IP: ${NODE_IP}"
```

---

## 2. Prepare the Node

SSH in and run all commands in this section **on the VM**:

```bash
ssh ubuntu@${NODE_IP}
```

### Hostname

```bash
sudo hostnamectl set-hostname k8s-node
```

### Disable swap

```bash
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
```

### Kernel modules and sysctl

```bash
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
```

---

## 3. Install containerd, runc, and CNI plugins

Run **on the VM**:

```bash
CONTAINERD_VER=2.0.2
RUNC_VER=1.2.4
CNI_VER=1.6.2

cd /tmp

# containerd
wget -q https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz
sudo tar xf containerd-${CONTAINERD_VER}-linux-amd64.tar.gz -C /usr/local

# runc
wget -q https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# CNI plugins
sudo mkdir -p /opt/cni/bin
wget -q https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz
sudo tar xf cni-plugins-linux-amd64-v${CNI_VER}.tgz -C /opt/cni/bin

# containerd config (enable systemd cgroup driver)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# containerd systemd unit
cat <<'EOF' | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
```

---

## 4. Generate TLS Certificates

Run these steps **on your local machine** (requires cfssl).

```bash
mkdir -p ~/k8s-certs && cd ~/k8s-certs
export NODE_IP="<paste IP from step 1>"
export NODE_NAME="k8s-node"
```

### 4.1 Certificate Authority

```bash
cat > ca-config.json <<'EOF'
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<'EOF'
{
  "CN": "Kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "Kubernetes", "OU": "CA" }]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

### 4.2 Admin certificate

```bash
cat > admin-csr.json <<'EOF'
{
  "CN": "admin",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "system:masters", "OU": "Kubernetes The Hard Way" }]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes admin-csr.json | cfssljson -bare admin
```

### 4.3 Kubelet certificate

The CN must match `system:node:<hostname>` and the SANs must include the node's hostname and IP.

```bash
cat > ${NODE_NAME}-csr.json <<EOF
{
  "CN": "system:node:${NODE_NAME}",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "system:nodes", "OU": "Kubernetes The Hard Way" }]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes \
  -hostname="${NODE_NAME},${NODE_IP}" \
  ${NODE_NAME}-csr.json | cfssljson -bare ${NODE_NAME}
```

### 4.4 kube-apiserver certificate

The SAN list includes the first service cluster IP (10.96.0.1), the node IP, and standard
Kubernetes DNS names.

```bash
cat > kubernetes-csr.json <<'EOF'
{
  "CN": "kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "Kubernetes", "OU": "Kubernetes The Hard Way" }]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes \
  -hostname="10.96.0.1,${NODE_IP},127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local" \
  kubernetes-csr.json | cfssljson -bare kubernetes
```

### 4.5 Service account key pair

```bash
cat > service-account-csr.json <<'EOF'
{
  "CN": "service-accounts",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "Kubernetes", "OU": "Kubernetes The Hard Way" }]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes service-account-csr.json | cfssljson -bare service-account
```

### 4.6 Component certificates (controller-manager, proxy, scheduler)

```bash
for COMPONENT in kube-controller-manager kube-proxy kube-scheduler; do
  cat > ${COMPONENT}-csr.json <<EOF
{
  "CN": "system:${COMPONENT}",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "system:${COMPONENT}", "OU": "Kubernetes The Hard Way" }]
}
EOF
  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
    -profile=kubernetes ${COMPONENT}-csr.json | cfssljson -bare ${COMPONENT}
done
```

### 4.7 Copy certificates to the node

```bash
scp ca.pem ca-key.pem \
    kubernetes.pem kubernetes-key.pem \
    service-account.pem service-account-key.pem \
    ${NODE_NAME}.pem ${NODE_NAME}-key.pem \
    ubuntu@${NODE_IP}:~/
```

---

## 5. Generate Kubeconfigs

Run **on your local machine**, in `~/k8s-certs`:

```bash
KUBERNETES_API="https://${NODE_IP}:6443"

# kubelet
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=${KUBERNETES_API} --kubeconfig=${NODE_NAME}.kubeconfig
kubectl config set-credentials system:node:${NODE_NAME} \
  --client-certificate=${NODE_NAME}.pem --client-key=${NODE_NAME}-key.pem --embed-certs=true \
  --kubeconfig=${NODE_NAME}.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=system:node:${NODE_NAME} --kubeconfig=${NODE_NAME}.kubeconfig
kubectl config use-context default --kubeconfig=${NODE_NAME}.kubeconfig

# kube-proxy
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=${KUBERNETES_API} --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials system:kube-proxy \
  --client-certificate=kube-proxy.pem --client-key=kube-proxy-key.pem --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=system:kube-proxy --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

# kube-controller-manager (connects to local API server)
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=https://127.0.0.1:6443 --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=kube-controller-manager.pem --client-key=kube-controller-manager-key.pem \
  --embed-certs=true --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=system:kube-controller-manager --kubeconfig=kube-controller-manager.kubeconfig
kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig

# kube-scheduler (connects to local API server)
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=https://127.0.0.1:6443 --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-credentials system:kube-scheduler \
  --client-certificate=kube-scheduler.pem --client-key=kube-scheduler-key.pem \
  --embed-certs=true --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=system:kube-scheduler --kubeconfig=kube-scheduler.kubeconfig
kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig

# admin
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=${KUBERNETES_API} --kubeconfig=admin.kubeconfig
kubectl config set-credentials admin \
  --client-certificate=admin.pem --client-key=admin-key.pem --embed-certs=true \
  --kubeconfig=admin.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=admin --kubeconfig=admin.kubeconfig
kubectl config use-context default --kubeconfig=admin.kubeconfig
```

Copy kubeconfigs to the node:

```bash
scp ${NODE_NAME}.kubeconfig kube-proxy.kubeconfig \
    kube-controller-manager.kubeconfig kube-scheduler.kubeconfig \
    ubuntu@${NODE_IP}:~/
```

---

## 6. Data Encryption Config

Run **on your local machine**:

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

scp encryption-config.yaml ubuntu@${NODE_IP}:~/
```

---

## 7. Bootstrap etcd

Run **on the VM**:

```bash
ETCD_VER=3.5.17
cd /tmp
wget -q https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-amd64.tar.gz
tar xf etcd-v${ETCD_VER}-linux-amd64.tar.gz
sudo mv etcd-v${ETCD_VER}-linux-amd64/etcd* /usr/local/bin/
rm -rf etcd-v${ETCD_VER}-linux-amd64*

sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd
sudo cp ~/ca.pem ~/kubernetes.pem ~/kubernetes-key.pem /etc/etcd/

INTERNAL_IP=$(hostname -I | awk '{print $1}')
ETCD_NAME=$(hostname -s)

cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${ETCD_NAME}=https://${INTERNAL_IP}:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now etcd
```

Verify:

```bash
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
```

---

## 8. Bootstrap the Control Plane

Run **on the VM**:

```bash
K8S_VER=1.32.3
cd /tmp
for BIN in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
  wget -q https://dl.k8s.io/release/v${K8S_VER}/bin/linux/amd64/${BIN}
  chmod +x ${BIN}
  sudo mv ${BIN} /usr/local/bin/
done

sudo mkdir -p /etc/kubernetes/config /var/lib/kubernetes

sudo cp ~/ca.pem ~/ca-key.pem \
       ~/kubernetes.pem ~/kubernetes-key.pem \
       ~/service-account.pem ~/service-account-key.pem \
       ~/encryption-config.yaml \
       /var/lib/kubernetes/

sudo cp ~/kube-controller-manager.kubeconfig ~/kube-scheduler.kubeconfig \
       /var/lib/kubernetes/
```

### kube-apiserver

```bash
INTERNAL_IP=$(hostname -I | awk '{print $1}')

cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=1 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://127.0.0.1:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-issuer=https://${INTERNAL_IP}:6443 \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.96.0.0/12 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### kube-controller-manager

```bash
cat <<'EOF' | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
  --bind-address=0.0.0.0 \
  --allocate-node-cidrs=true \
  --cluster-cidr=10.200.0.0/16 \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \
  --leader-elect=true \
  --root-ca-file=/var/lib/kubernetes/ca.pem \
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \
  --service-cluster-ip-range=10.96.0.0/12 \
  --use-service-account-credentials=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### kube-scheduler

```bash
cat <<'EOF' | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

cat <<'EOF' | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --config=/etc/kubernetes/config/kube-scheduler.yaml \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Start control plane

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kube-apiserver kube-controller-manager kube-scheduler

# Wait ~10 seconds, then verify
kubectl get --raw='/readyz?verbose' --kubeconfig=~/admin.kubeconfig
```

---

## 9. Bootstrap the Worker (same node)

Run **on the VM**:

```bash
K8S_VER=1.32.3
cd /tmp
for BIN in kubelet kube-proxy; do
  wget -q https://dl.k8s.io/release/v${K8S_VER}/bin/linux/amd64/${BIN}
  chmod +x ${BIN}
  sudo mv ${BIN} /usr/local/bin/
done

HOSTNAME="k8s-node"
sudo mkdir -p /var/lib/kubelet /var/lib/kube-proxy /var/run/kubernetes

sudo cp ~/${HOSTNAME}.pem ~/${HOSTNAME}-key.pem /var/lib/kubelet/
sudo cp ~/${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp ~/ca.pem /var/lib/kubernetes/
```

### kubelet config

```bash
cat <<'EOF' | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.96.0.10"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/k8s-node.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/k8s-node-key.pem"
cgroupDriver: systemd
EOF

cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --register-node=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### kube-proxy config

```bash
sudo cp ~/kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

cat <<'EOF' | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF

cat <<'EOF' | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now kubelet kube-proxy
```

---

## 10. RBAC for Kubelet API Access

The API server connects back to kubelet using the `kubernetes` TLS identity. Grant it the
necessary permissions. Run **on the VM**:

```bash
cat <<'EOF' | kubectl apply --kubeconfig=~/admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-apiserver-to-kubelet
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
rules:
  - apiGroups: [""]
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF
```

---

## 11. Pod Networking with Flannel

Flannel uses VXLAN to tunnel pod traffic between nodes — this works on OpenStack without
any allowed-address-pairs changes.

Run **on the VM**:

```bash
kubectl apply --kubeconfig=~/admin.kubeconfig \
  -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Flannel reads the node's `spec.podCIDR` (allocated by the controller-manager) and sets up
a VXLAN tunnel automatically.

---

## 12. Deploy CoreDNS

Run **on the VM**:

```bash
cat <<'EOF' | kubectl apply --kubeconfig=~/admin.kubeconfig -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:coredns
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
rules:
  - apiGroups: [""]
    resources: [endpoints, services, pods, namespaces]
    verbs: [list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:coredns
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
  - kind: ServiceAccount
    name: coredns
    namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health { lameduck 5s }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf { max_concurrent 1000 }
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      serviceAccountName: coredns
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: coredns
          image: registry.k8s.io/coredns/coredns:v1.11.4
          args: ["-conf", "/etc/coredns/Corefile"]
          resources:
            limits:
              memory: 170Mi
            requests:
              cpu: 100m
              memory: 70Mi
          ports:
            - containerPort: 53
              name: dns
              protocol: UDP
            - containerPort: 53
              name: dns-tcp
              protocol: TCP
            - containerPort: 9153
              name: metrics
              protocol: TCP
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
              readOnly: true
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              add: [NET_BIND_SERVICE]
              drop: [all]
            readOnlyRootFilesystem: true
          livenessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 60
            failureThreshold: 5
          readinessProbe:
            httpGet: { path: /ready, port: 8181 }
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
              - key: Corefile
                path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: CoreDNS
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.96.0.10
  ports:
    - name: dns
      port: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      protocol: TCP
    - name: metrics
      port: 9153
      protocol: TCP
EOF
```

---

## 13. Configure kubectl on Your Local Machine

Run **on your local machine**, in `~/k8s-certs`:

```bash
kubectl config set-cluster kubernetes \
  --certificate-authority=ca.pem --embed-certs=true \
  --server=https://${NODE_IP}:6443

kubectl config set-credentials admin \
  --client-certificate=admin.pem --client-key=admin-key.pem --embed-certs=true

kubectl config set-context kubernetes \
  --cluster=kubernetes --user=admin

kubectl config use-context kubernetes
```

---

## 14. Smoke Test

```bash
# Node should be Ready
kubectl get nodes

# System pods should be Running
kubectl get pods -n kube-system

# Deploy nginx
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort

# Test DNS resolution inside the cluster
kubectl run busybox --image=busybox:1.28 --restart=Never --rm -it \
  -- nslookup kubernetes

# Test secrets are encrypted at rest
kubectl create secret generic test-secret --from-literal=key=value
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/default/test-secret \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem \
  | hexdump -C | head
# The value should be unreadable (encrypted with AES-CBC)
```
