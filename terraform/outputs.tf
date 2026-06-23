output "ssh_private_key_file" {
  description = "The path to the local SSH private key file used to access all instances"
  value       = local_sensitive_file.private_key.filename
}

output "scylla_node_private_ips" {
  description = "The private IP addresses of the Scylla DB nodes (Multi-AZ)"
  value       = aws_instance.scylla[*].private_ip
}

output "scylla_node_public_ips" {
  description = "The public IP addresses of the Scylla DB nodes (for SSH)"
  value       = aws_instance.scylla[*].public_ip
}

output "loader_node_private_ips" {
  description = "The private IP addresses of the Latte loaders"
  value       = aws_instance.loader[*].private_ip
}

output "loader_node_public_ips" {
  description = "The public IP addresses of the Latte loaders (for SSH/Benchmarking)"
  value       = aws_instance.loader[*].public_ip
}

output "monitoring_node_public_ip" {
  description = "The public IP address of the Scylla Monitoring node"
  value       = aws_instance.monitoring.public_ip
}

output "grafana_url" {
  description = "The URL of the Grafana monitoring dashboards"
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "ssh_monitoring_command" {
  description = "Shorthand SSH command to access the Monitoring node"
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.monitoring.public_ip}"
}

output "ssh_loader_commands" {
  description = "Shorthand SSH commands to access the Loaders"
  value       = [for idx, ip in aws_instance.loader[*].public_ip : "ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${ip}"]
}

output "benchmarking_quickstart_guide" {
  description = "Quick commands to run the automated benchmark from your local machine once provisioning is complete (allow 2-3 mins for boot setup)"
  value       = <<EOF

========================================================================================
                          SCYLLA MULTI-AZ BENCHMARK QUICKSTART
========================================================================================

1. RUN THE ENTIRE AUTOMATED BENCHMARK PIPELINE (From your local machine's project root):
   $ ./run_benchmark.sh

   *(Optional)* Customize the duration (e.g., to run for 10 minutes instead of the default 5m):
   $ ./run_benchmark.sh --duration 10m

2. OR SSH INTO LOADER-0 DIRECTLY (If you want to run manual tests):
   $ ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.loader[0].public_ip}

3. ACCESS GRAFANA MONITORING TO ANALYZE REAL-TIME METRICS & LATENCY:
   URL: http://${aws_instance.monitoring.public_ip}:3000

========================================================================================
EOF
}
