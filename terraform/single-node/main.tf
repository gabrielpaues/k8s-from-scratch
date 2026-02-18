module "k8s_sg" {
  source      = "github.com/safespring-community/terraform-modules/v2-compute-security-group"
  name        = "k8s-single-node"
  description = "Kubernetes single-node security group"
  rules = {
    # SSH from anywhere — restrict to your own IP in production
    ssh = {
      ip_protocol = "tcp"
      from_port   = "22"
      to_port     = "22"
      cidr        = "0.0.0.0/0"
    }
    # Kubernetes API server
    apiserver = {
      ip_protocol = "tcp"
      from_port   = "6443"
      to_port     = "6443"
      cidr        = "0.0.0.0/0"
    }
    # Allow all traffic within this security group (node-to-pod, health checks)
    internal = {
      ip_protocol     = "-1"
      from_port       = "0"
      to_port         = "0"
      remote_group_id = "self"
    }
  }
}

module "k8s_node" {
  source          = "github.com/safespring-community/terraform-modules/v2-compute-instance"
  name            = var.node_name
  key_pair_name   = var.key_pair_name
  flavor          = var.flavor
  image           = var.image
  network         = var.network
  security_groups = [module.k8s_sg.name]
}
