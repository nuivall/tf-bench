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
  description = "Quick commands to run inside any of the loaders after provisioning is complete (allow 2-3 mins for boot setup)"
  value       = <<EOF

========================================================================================
                          SCYLLA MULTI-AZ BENCHMARK QUICKSTART
========================================================================================

1. SSH INTO LOADER-0:
   $ ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.loader[0].public_ip}

2. INITIALIZE DATABASE SCHEMA (Creates keyspace & tables with Replication Factor = 3):
   $ latte schema workloads/workload.rn ${join(" ", aws_instance.scylla[*].private_ip)}

3. PRE-POPULATE 1,000,000 ROWS INTO THE DATABASE (Creates consistent dataset first):
   $ latte run -f load -d 1000000 --threads 8 --concurrency 64 workloads/workload.rn ${join(" ", aws_instance.scylla[*].private_ip)}

4. RUN STEADY-STATE 50/50 CONCURRENT MIXED WORKLOAD FOR 10 MINUTES:
   $ latte run -f read:0.5 -f write:0.5 -d 10m --threads 8 --concurrency 64 workloads/workload.rn ${join(" ", aws_instance.scylla[*].private_ip)}

5. SIMULATE A CONNECT STORM IN BACKGROUND (Run in another terminal on any Loader):
   $ ./workloads/connect_storm.sh ${join(" ", aws_instance.scylla[*].private_ip)}

6. ACCESS GRAFANA MONITORING TO ANALYZE REAL-TIME METRICS & LATENCY:
   URL: http://${aws_instance.monitoring.public_ip}:3000

========================================================================================
EOF
}
