variable "key_pair_name" {
  description = "Name of an existing SSH key pair in your OpenStack project"
  type        = string
}

variable "flavor" {
  description = "OpenStack flavor. Run 'openstack flavor list' to see available options."
  type        = string
  default     = "l2.c4r8.100"
}

variable "image" {
  description = "Ubuntu 24.04 image name as it appears in OpenStack"
  type        = string
  default     = "ubuntu-24.04"
}

variable "network" {
  description = "OpenStack network name to attach the instance to"
  type        = string
  default     = "default"
}

variable "node_name" {
  description = "Hostname for the Kubernetes node"
  type        = string
  default     = "k8s-node"
}
