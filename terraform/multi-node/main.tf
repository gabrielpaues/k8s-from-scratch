# Security group shared by all Kubernetes nodes (controllers + workers)
module "k8s_sg" {
  source      = "github.com/safespring-community/terraform-modules/v2-compute-security-group"
  name        = "k8s-nodes"
  description = "Kubernetes nodes: internal + SSH + API server"
  rules = {
    ssh = {
      ip_protocol = "tcp"
      from_port   = "22"
      to_port     = "22"
      cidr        = "0.0.0.0/0"
    }
    # Allow all traffic between nodes in this group (etcd, kubelet, Flannel VXLAN, etc.)
    internal = {
      ip_protocol     = "-1"
      from_port       = "0"
      to_port         = "0"
      remote_group_id = "self"
    }
  }
}

# Security group for the load balancer (public-facing API server endpoint)
module "k8s_lb_sg" {
  source      = "github.com/safespring-community/terraform-modules/v2-compute-security-group"
  name        = "k8s-lb"
  description = "HAProxy load balancer for Kubernetes API"
  rules = {
    ssh = {
      ip_protocol = "tcp"
      from_port   = "22"
      to_port     = "22"
      cidr        = "0.0.0.0/0"
    }
    apiserver = {
      ip_protocol = "tcp"
      from_port   = "6443"
      to_port     = "6443"
      cidr        = "0.0.0.0/0"
    }
  }
}

# HAProxy load balancer
module "k8s_lb" {
  source          = "github.com/safespring-community/terraform-modules/v2-compute-instance"
  name            = "k8s-lb"
  key_pair_name   = var.key_pair_name
  flavor          = var.lb_flavor
  image           = var.image
  network         = var.network
  security_groups = [module.k8s_lb_sg.name]
}

# Controller nodes
module "k8s_controllers" {
  source          = "github.com/safespring-community/terraform-modules/v2-compute-instance"
  count           = var.controller_count
  name            = "k8s-controller-${count.index}"
  key_pair_name   = var.key_pair_name
  flavor          = var.controller_flavor
  image           = var.image
  network         = var.network
  security_groups = [module.k8s_sg.name]
}

# Worker nodes
module "k8s_workers" {
  source          = "github.com/safespring-community/terraform-modules/v2-compute-instance"
  count           = var.worker_count
  name            = "k8s-worker-${count.index}"
  key_pair_name   = var.key_pair_name
  flavor          = var.worker_flavor
  image           = var.image
  network         = var.network
  security_groups = [module.k8s_sg.name]
}
