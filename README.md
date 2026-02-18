# k8s-from-scratch

Setting up Kubernetes from scratch ("the hard way") on OpenStack (Safespring) using Ubuntu 24.04 VMs — no kubeadm, no installers.

## Structure

```
terraform/
  single-node/    # One VM: control plane + worker combined
  multi-node/     # 3 controllers + 3 workers + 1 HAProxy load balancer
docs/
  01-prerequisites.md   # Install Terraform, kubectl, cfssl
  02-single-node.md     # Full single-node cluster setup
  03-multi-node.md      # Scale to 3-controller + 3-worker HA cluster
```

## Quick Start

1. [Install prerequisites](docs/01-prerequisites.md)
2. [Set up a single-node cluster](docs/02-single-node.md)
3. [Scale to a 3+3 HA cluster](docs/03-multi-node.md)

## Component Versions

| Component   | Version |
|-------------|---------|
| Kubernetes  | 1.32.3  |
| etcd        | 3.5.17  |
| containerd  | 2.0.2   |
| runc        | 1.2.4   |
| CNI plugins | 1.6.2   |
| Flannel     | latest  |
| CoreDNS     | 1.11.4  |

## Network Layout

| Range          | Purpose               |
|----------------|-----------------------|
| 10.96.0.0/12   | Service cluster IPs   |
| 10.96.0.10     | CoreDNS               |
| 10.200.0.0/16  | Pod network (Flannel)  |
