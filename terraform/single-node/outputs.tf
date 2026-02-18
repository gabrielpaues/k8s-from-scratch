output "node_ip" {
  description = "IPv4 address of the Kubernetes node"
  value       = module.k8s_node.IPv4
}
