output "lb_ip" {
  description = "IPv4 address of the HAProxy load balancer"
  value       = module.k8s_lb.IPv4
}

output "controller_ips" {
  description = "IPv4 addresses of controller nodes"
  value       = [for m in module.k8s_controllers : m.IPv4]
}

output "worker_ips" {
  description = "IPv4 addresses of worker nodes"
  value       = [for m in module.k8s_workers : m.IPv4]
}
