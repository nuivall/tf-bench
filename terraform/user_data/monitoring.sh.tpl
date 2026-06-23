#!/bin/bash
# ScyllaDB Monitoring Node provisioning with Docker and Official Scylla Monitoring Stack
set -xe

# Redirect stdout/stderr to a log file for debugging
exec > >(tee /var/log/monitoring-setup.log | logger -t user-data -s 2>/dev/null) 2>&1

echo "========================================="
echo " Starting Scylla Monitoring provisioning"
echo "========================================="

# 1. Install Docker and Docker Compose
apt-get update && apt-get install -y docker.io docker-compose git

# Ensure docker service is running and user has permissions
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# 2. Clone official Scylla Monitoring Stack
git clone https://github.com/scylladb/scylla-monitoring.git /home/ubuntu/scylla-monitoring
cd /home/ubuntu/scylla-monitoring

# 3. Create target configuration file for the Scylla cluster
cat <<'EOF' > /home/ubuntu/scylla-monitoring/prometheus/scylla_servers.yml
${scylla_servers_yaml}
EOF

# Fix permissions
chown -R ubuntu:ubuntu /home/ubuntu/scylla-monitoring

# 4. Start the Scylla Monitoring Stack
# -d specifies Prometheus data dir, -b specifies Grafana data dir
# -v 6.0 loads dashboards matching ScyllaDB 6.0
echo "Launching Prometheus & Grafana containers..."
./start-all.sh -d /var/lib/prometheus -b /var/lib/grafana -v ${scylla_version}

echo "========================================="
echo " Monitoring Stack fully active on port 3000!"
echo "========================================="
