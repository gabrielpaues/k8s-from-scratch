# 3-Controller + 3-Worker HA Cluster

This guide scales from the single-node setup to a production-style HA cluster:

- **3 controller nodes**: etcd cluster + Kubernetes control plane
- **3 worker nodes**: containerd + kubelet + kube-proxy
- **1 HAProxy VM**: load balances `kubectl` and API server traffic across the 3 controllers

Work through [02-single-node.md](02-single-node.md) first — this guide highlights only the
differences and additions.

---

## 1. Provision Infrastructure

```bash
cd terraform/multi-node
export TF_VAR_key_pair_name="my-key"

terraform init
terraform apply
```

Export the IPs:

```bash
export LB_IP=$(terraform output -raw lb_ip)
export CONTROLLER_IPS=($(terraform output -json controller_ips | jq -r '.[]'))
export WORKER_IPS=($(terraform output -json worker_ips | jq -r '.[]'))

# Shorthand variables used throughout this guide
C0=${CONTROLLER_IPS[0]}
C1=${CONTROLLER_IPS[1]}
C2=${CONTROLLER_IPS[2]}
W0=${WORKER_IPS[0]}
W1=${WORKER_IPS[1]}
W2=${WORKER_IPS[2]}
```

Set hostnames on each node (run once per node via SSH):

```bash
for i in 0 1 2; do
  ssh ubuntu@${CONTROLLER_IPS[$i]} "sudo hostnamectl set-hostname k8s-controller-${i}"
  ssh ubuntu@${WORKER_IPS[$i]}     "sudo hostnamectl set-hostname k8s-worker-${i}"
done
ssh ubuntu@${LB_IP} "sudo hostnamectl set-hostname k8s-lb"
```

---

## 2. Prepare All Nodes

Every node — controller and worker alike — needs the same kernel modules (`overlay`, `br_netfilter`), sysctl settings, and container runtime. Controllers run only control-plane processes, but containerd is still needed there because static control-plane pods (if you ever add them) and Flannel's DaemonSet pod run on controllers too. The kernel settings enable iptables bridge filtering and IP forwarding, which are prerequisites for pod networking and kube-proxy.

Run the kernel/sysctl setup and install containerd on **every controller and worker**
(same commands as [02-single-node.md §2–3](02-single-node.md)):

```bash
for IP in ${CONTROLLER_IPS[@]} ${WORKER_IPS[@]}; do
  ssh ubuntu@${IP} 'bash -s' << 'ENDSSH'
    sudo swapoff -a
    sudo sed -i '/swap/d' /etc/fstab

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

    # containerd
    CONTAINERD_VER=2.0.2 RUNC_VER=1.2.4 CNI_VER=1.6.2
    cd /tmp
    wget -q https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz
    sudo tar xf containerd-${CONTAINERD_VER}-linux-amd64.tar.gz -C /usr/local
    wget -q https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64
    sudo install -m 755 runc.amd64 /usr/local/sbin/runc
    sudo mkdir -p /opt/cni/bin
    wget -q https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz
    sudo tar xf cni-plugins-linux-amd64-v${CNI_VER}.tgz -C /opt/cni/bin
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    cat <<'EOF' | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
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
ENDSSH
done
```

---

## 3. Generate TLS Certificates

Run **on your local machine**, in `~/k8s-certs`.

The key difference from single-node: the API server cert must include all controller IPs,
the LB IP, and all DNS names.

```bash
mkdir -p ~/k8s-certs && cd ~/k8s-certs
```

Re-use the `ca-config.json` and CA from the single-node guide, or regenerate:

```bash
# (skip if ca.pem already exists)
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
{ "CN": "Kubernetes", "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "Kubernetes", "OU": "CA" }] }
EOF
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

### Admin + component certificates

Same as single-node (admin, kube-controller-manager, kube-proxy, kube-scheduler,
service-account). Run those commands verbatim.

### API server certificate — all controller and LB IPs as SANs

TLS clients (kubectl, kubelet, kube-proxy) verify the server certificate's Subject Alternative Names against the address they connected to. In an HA setup clients connect through the LB IP, but each API server also serves directly on its own IP. All of these addresses — every controller IP, the LB IP, `127.0.0.1`, and the standard DNS names — must appear as SANs in a single shared certificate, otherwise TLS handshakes will fail depending on which path traffic takes.

```bash
# Substitute real IPs
C0="<controller-0 IP>"
C1="<controller-1 IP>"
C2="<controller-2 IP>"
LB_IP="<LB IP>"

cat > kubernetes-csr.json <<'EOF'
{
  "CN": "kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "SE", "O": "Kubernetes", "OU": "Kubernetes The Hard Way" }]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes \
  -hostname="10.96.0.1,${C0},${C1},${C2},${LB_IP},127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local" \
  kubernetes-csr.json | cfssljson -bare kubernetes
```

### etcd peer certificate

etcd peers verify each other with TLS. Reuse the `kubernetes.pem` cert (its SANs include
all controller IPs), or generate a dedicated etcd cert with controller IPs in the SANs.

### Kubelet certificate — one per worker node

```bash
for i in 0 1 2; do
  NODE_NAME="k8s-worker-${i}"
  NODE_IP="${WORKER_IPS[$i]}"

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
done
```

### Distribute certificates

```bash
# Controllers: CA, API server cert, service-account keys
for IP in ${C0} ${C1} ${C2}; do
  scp ca.pem ca-key.pem \
      kubernetes.pem kubernetes-key.pem \
      service-account.pem service-account-key.pem \
      ubuntu@${IP}:~/
done

# Workers: CA + their own kubelet cert
for i in 0 1 2; do
  scp ca.pem \
      k8s-worker-${i}.pem k8s-worker-${i}-key.pem \
      ubuntu@${WORKER_IPS[$i]}:~/
done
```

---

## 4. Generate Kubeconfigs

Run **on your local machine**:

```bash
LB_API="https://${LB_IP}:6443"

# Worker kubeconfigs (kubelet uses the LB endpoint)
for i in 0 1 2; do
  NODE="k8s-worker-${i}"
  kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
    --server=${LB_API} --kubeconfig=${NODE}.kubeconfig
  kubectl config set-credentials system:node:${NODE} \
    --client-certificate=${NODE}.pem --client-key=${NODE}-key.pem --embed-certs=true \
    --kubeconfig=${NODE}.kubeconfig
  kubectl config set-context default --cluster=kubernetes \
    --user=system:node:${NODE} --kubeconfig=${NODE}.kubeconfig
  kubectl config use-context default --kubeconfig=${NODE}.kubeconfig
done

# kube-proxy (uses LB)
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=${LB_API} --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials system:kube-proxy \
  --client-certificate=kube-proxy.pem --client-key=kube-proxy-key.pem --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=system:kube-proxy --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

# kube-controller-manager and kube-scheduler connect to local API server
for COMPONENT in kube-controller-manager kube-scheduler; do
  kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
    --server=https://127.0.0.1:6443 --kubeconfig=${COMPONENT}.kubeconfig
  kubectl config set-credentials system:${COMPONENT} \
    --client-certificate=${COMPONENT}.pem --client-key=${COMPONENT}-key.pem \
    --embed-certs=true --kubeconfig=${COMPONENT}.kubeconfig
  kubectl config set-context default --cluster=kubernetes \
    --user=system:${COMPONENT} --kubeconfig=${COMPONENT}.kubeconfig
  kubectl config use-context default --kubeconfig=${COMPONENT}.kubeconfig
done

# admin (uses LB)
kubectl config set-cluster kubernetes --certificate-authority=ca.pem --embed-certs=true \
  --server=${LB_API} --kubeconfig=admin.kubeconfig
kubectl config set-credentials admin \
  --client-certificate=admin.pem --client-key=admin-key.pem --embed-certs=true \
  --kubeconfig=admin.kubeconfig
kubectl config set-context default --cluster=kubernetes \
  --user=admin --kubeconfig=admin.kubeconfig
kubectl config use-context default --kubeconfig=admin.kubeconfig
```

Distribute kubeconfigs:

```bash
# Controllers
for IP in ${C0} ${C1} ${C2}; do
  scp kube-controller-manager.kubeconfig kube-scheduler.kubeconfig \
      admin.kubeconfig ubuntu@${IP}:~/
done

# Workers
for i in 0 1 2; do
  scp k8s-worker-${i}.kubeconfig kube-proxy.kubeconfig \
      ubuntu@${WORKER_IPS[$i]}:~/
done
```

---

## 5. Data Encryption Config

Same as single-node. Copy `encryption-config.yaml` to all controllers:

```bash
for IP in ${C0} ${C1} ${C2}; do
  scp encryption-config.yaml ubuntu@${IP}:~/
done
```

---

## 6. Bootstrap etcd Cluster

etcd uses the **Raft** consensus algorithm to keep all members in sync. With three members the cluster can tolerate the loss of one node and still have a quorum (2 of 3). All three members must be declared in `--initial-cluster` before the cluster is formed for the first time — etcd uses this list to bootstrap peer discovery. The `--initial-cluster-state new` flag tells etcd to expect a fresh cluster; once running, new members are added via `etcdctl member add` instead.

All client and peer communication is TLS-authenticated (`--peer-client-cert-auth`, `--client-cert-auth`), so a compromised node cannot inject data or read secrets from the rest of the cluster.

The three etcd members must know each other up-front via `--initial-cluster`.

Run **on each controller** (adjust `THIS_IP`, `THIS_NAME`, and the peer list):

```bash
# Run this on controller-0 (repeat for controller-1 and controller-2, changing THIS_NAME/THIS_IP)
THIS_NAME="k8s-controller-0"   # k8s-controller-1 / k8s-controller-2 on others
THIS_IP="${C0}"                 # ${C1} / ${C2} on others

ETCD_VER=3.5.17
cd /tmp
wget -q https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-amd64.tar.gz
tar xf etcd-v${ETCD_VER}-linux-amd64.tar.gz
sudo mv etcd-v${ETCD_VER}-linux-amd64/etcd* /usr/local/bin/
rm -rf etcd-v${ETCD_VER}-linux-amd64*

sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd
sudo cp ~/ca.pem ~/kubernetes.pem ~/kubernetes-key.pem /etc/etcd/

cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${THIS_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${THIS_IP}:2380 \\
  --listen-peer-urls https://${THIS_IP}:2380 \\
  --listen-client-urls https://${THIS_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${THIS_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster k8s-controller-0=https://${C0}:2380,k8s-controller-1=https://${C1}:2380,k8s-controller-2=https://${C2}:2380 \\
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

Verify on any controller:

```bash
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
# Expect 3 members listed
```

---

## 7. Bootstrap the Control Plane (all 3 controllers)

Download binaries on each controller (same as single-node §8). Then:

### kube-apiserver

Each controller runs its own API server instance — they are all active simultaneously (active/active). There is no leader election for the API server itself; the HAProxy load balancer distributes requests across all three. Key differences from single-node:

- `--apiserver-count=3` — tells the API server how many peers exist, used for endpoint advertisement.
- `--etcd-servers` lists all three etcd endpoints — the API server connects to whichever etcd member is reachable and will automatically failover if one is down.
- `--service-account-issuer` points to the LB IP — this is the OIDC issuer URL embedded in service-account tokens, so tokens are valid regardless of which API server signed them.

Run **on each controller** (substitute `THIS_IP` appropriately):

```bash
THIS_IP="<this controller's IP>"

sudo mkdir -p /etc/kubernetes/config /var/lib/kubernetes
sudo cp ~/ca.pem ~/ca-key.pem ~/kubernetes.pem ~/kubernetes-key.pem \
       ~/service-account.pem ~/service-account-key.pem \
       ~/encryption-config.yaml /var/lib/kubernetes/
sudo cp ~/kube-controller-manager.kubeconfig ~/kube-scheduler.kubeconfig \
       /var/lib/kubernetes/

cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${THIS_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
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
  --etcd-servers=https://${C0}:2379,https://${C1}:2379,https://${C2}:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-issuer=https://${LB_IP}:6443 \\
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

### kube-controller-manager and kube-scheduler

Unlike the API server, the controller manager and scheduler use **leader election** (`--leader-elect=true` is the default). All three instances run and compete for a lease stored in the API server; only the current leader actively reconciles state — the others stand by and take over instantly if the leader's lease expires. This prevents split-brain: two controller managers running simultaneously could make conflicting decisions (e.g. both trying to scale the same deployment). The unit files are identical to the single-node guide.

Identical to single-node. Copy those unit files and start:

```bash
# (copy unit files as in single-node guide)
sudo systemctl daemon-reload
sudo systemctl enable --now kube-apiserver kube-controller-manager kube-scheduler
```

---

## 8. Set Up HAProxy Load Balancer

The load balancer gives clients (kubectl, kubelet, kube-proxy) a single stable endpoint — the LB IP — so they don't need to know which controller is currently healthy or how many there are. **HAProxy** in TCP mode (`mode tcp`) proxies raw TLS connections without terminating them, meaning the API server's certificate is presented directly to clients and end-to-end TLS is preserved. `option tcp-check` performs a TCP health check on each backend; HAProxy stops sending traffic to a controller the moment its port 6443 stops accepting connections. `balance roundrobin` distributes new connections evenly across all healthy controllers.

SSH into the load balancer VM and run:

```bash
sudo apt-get update && sudo apt-get install -y haproxy

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 2000
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend k8s-api
    bind *:6443
    default_backend k8s-controllers

backend k8s-controllers
    balance roundrobin
    option tcp-check
    server controller-0 ${C0}:6443 check
    server controller-1 ${C1}:6443 check
    server controller-2 ${C2}:6443 check
EOF

sudo systemctl enable --now haproxy
```

Verify from your local machine:

```bash
curl -k https://${LB_IP}:6443/version
```

---

## 9. Bootstrap Worker Nodes

Workers run only **kubelet** and **kube-proxy** — no control-plane processes. kubelet registers itself with the API server via the kubeconfig (which points to the LB), so if a controller goes down mid-registration kubelet retries against a healthy one. kube-proxy similarly watches the API server through the LB for Service/Endpoint changes and writes iptables rules locally. Each worker gets its own TLS certificate (`system:node:<hostname>`) so the NodeRestriction admission plugin can enforce that it can only modify its own Node object and pods scheduled to it.

For each worker node, follow the same steps as single-node §9, but:

- Replace `k8s-node` with the worker hostname (e.g. `k8s-worker-0`)
- The kubelet kubeconfig already points to the LB
- Skip the control plane setup steps

```bash
# Run on each worker — adjust NODE_NAME per worker
NODE_NAME="k8s-worker-0"   # k8s-worker-1, k8s-worker-2 on others

K8S_VER=1.32.3
cd /tmp
for BIN in kubelet kube-proxy; do
  wget -q https://dl.k8s.io/release/v${K8S_VER}/bin/linux/amd64/${BIN}
  chmod +x ${BIN}
  sudo mv ${BIN} /usr/local/bin/
done

sudo mkdir -p /var/lib/kubelet /var/lib/kube-proxy /var/run/kubernetes /var/lib/kubernetes

sudo cp ~/${NODE_NAME}.pem ~/${NODE_NAME}-key.pem /var/lib/kubelet/
sudo cp ~/${NODE_NAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp ~/ca.pem /var/lib/kubernetes/
sudo cp ~/kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
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
tlsCertFile: "/var/lib/kubelet/${NODE_NAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${NODE_NAME}-key.pem"
cgroupDriver: systemd
EOF

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

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

Same as single-node §10. Run once from any controller using the admin kubeconfig.

---

## 11. Pod Networking with Flannel

Flannel runs as a **DaemonSet**, meaning one pod per node across all controllers and workers. Each Flannel pod reads its node's `spec.podCIDR` (assigned by the controller-manager) and programs a `flannel.1` VXLAN interface for that subnet. When a pod on worker-0 sends a packet to a pod on worker-1, the kernel encapsulates it in a VXLAN UDP frame addressed to worker-1's node IP; Flannel on worker-1 decapsulates it and delivers it to the destination pod. This tunnel layer means OpenStack never sees pod-source IPs, so no `allowed-address-pairs` changes are needed — the only address OpenStack sees is the node's own IP.

Apply from any controller (or from your local machine with `--kubeconfig` pointing to the
LB):

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Patch the CIDR to match this cluster (the upstream manifest defaults to `10.244.0.0/16`):

```bash
kubectl patch configmap -n kube-flannel kube-flannel-cfg --type=merge \
  -p '{"data":{"net-conf.json":"{\"Network\":\"10.200.0.0/16\",\"Backend\":{\"Type\":\"vxlan\"}}"}}'
kubectl rollout restart ds -n kube-flannel kube-flannel-ds
```

---

## 12. Deploy CoreDNS

CoreDNS is deployed once for the whole cluster — it runs as a Deployment (one replica by default) and is reachable at the fixed ClusterIP `10.96.0.10` from every pod on every worker. In a production setup you would increase the replica count to 2 so DNS survives a pod restart, and optionally add an anti-affinity rule to spread the replicas across workers. The manifest is identical to the single-node guide.

Same manifest as single-node §12. Apply once:

```bash
kubectl apply -f - < /path/to/coredns-manifest.yaml
# or copy the manifest from 02-single-node.md and apply it here
```

---

## 13. Configure kubectl on Your Local Machine

```bash
kubectl config set-cluster kubernetes \
  --certificate-authority=~/k8s-certs/ca.pem --embed-certs=true \
  --server=https://${LB_IP}:6443

kubectl config set-credentials admin \
  --client-certificate=~/k8s-certs/admin.pem \
  --client-key=~/k8s-certs/admin-key.pem --embed-certs=true

kubectl config set-context kubernetes --cluster=kubernetes --user=admin
kubectl config use-context kubernetes
```

---

## 14. Verify the Cluster

```bash
# Six nodes should appear (3 controllers + 3 workers)
kubectl get nodes -o wide

# etcd cluster health
ssh ubuntu@${C0} "sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://${C0}:2379,https://${C1}:2379,https://${C2}:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem"

# Deploy a workload across workers
kubectl create deployment nginx --image=nginx --replicas=3
kubectl get pods -o wide   # pods should spread across worker nodes
```
