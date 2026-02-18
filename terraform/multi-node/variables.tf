variable "key_pair_name" {
  description = "Name of an existing SSH key pair in your OpenStack project"
  type        = string
}

variable "controller_flavor" {
  description = "Flavor for controller nodes"
  type        = string
  default     = "l2.c4r8.100"
}

variable "worker_flavor" {
  description = "Flavor for worker nodes"
  type        = string
  default     = "l2.c4r8.100"
}

variable "lb_flavor" {
  description = "Flavor for the HAProxy load balancer"
  type        = string
  default     = "l2.c2r4.100"
}

variable "image" {
  description = "Ubuntu 24.04 image name as it appears in OpenStack"
  type        = string
  default     = "ubuntu-24.04"
}

variable "network" {
  description = "OpenStack network name"
  type        = string
  default     = "default"
}

variable "controller_count" {
  description = "Number of controller nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}
