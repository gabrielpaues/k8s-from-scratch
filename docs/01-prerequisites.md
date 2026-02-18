# Prerequisites

All commands in this guide are run either on your **local machine** (macOS) or on the **remote VMs** via SSH. Each section is labelled accordingly.

## Local machine: Install Terraform

```bash
brew install terraform
terraform version  # should be >= 1.6.0
```

If you prefer managing multiple Terraform versions:

```bash
brew install tfenv
tfenv install latest
tfenv use latest
```

## Local machine: Install kubectl

```bash
brew install kubectl
```

## Local machine: Install cfssl

cfssl is used to generate all TLS certificates.

```bash
brew install cfssl
```

On Linux:

```bash
CFSSL_VER=1.6.5
sudo install -m755 <(curl -sL https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VER}/cfssl_${CFSSL_VER}_linux_amd64)   /usr/local/bin/cfssl
sudo install -m755 <(curl -sL https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VER}/cfssljson_${CFSSL_VER}_linux_amd64) /usr/local/bin/cfssljson
```

## Local machine: Configure OpenStack credentials

Source your OpenStack RC file (downloadable from Horizon → Project → API Access):

```bash
source ~/openstack-rc.sh
# enter your password when prompted
```

Verify it works:

```bash
openstack server list
openstack flavor list   # note a flavor name like l2.c4r8.100
openstack image list    # confirm ubuntu-24.04 exists
```

## Local machine: Upload an SSH key pair to OpenStack

If you do not yet have a key pair in your project:

```bash
openstack keypair create --public-key ~/.ssh/id_rsa.pub my-key
```

Use the name `my-key` (or whatever you chose) as `key_pair_name` when running Terraform.
