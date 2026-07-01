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
# Pin to the latest STABLE release branch (branch-4.16 / v4.6.x). Do NOT use the
# default 'master' branch: it is the unstable development branch and currently
# passes flags that the bundled Prometheus image rejects, breaking startup.
# branch-4.16 ships the dashboard sets up to 2026.2 (selected via -v below).
MONITORING_BRANCH="branch-4.16"
git clone --branch "$MONITORING_BRANCH" --depth 1 https://github.com/scylladb/scylla-monitoring.git /home/ubuntu/scylla-monitoring
cd /home/ubuntu/scylla-monitoring

# 3. Create target configuration file for the Scylla cluster
cat <<'EOF' > /home/ubuntu/scylla-monitoring/prometheus/scylla_servers.yml
${scylla_servers_yaml}
EOF

# Fix permissions
chown -R ubuntu:ubuntu /home/ubuntu/scylla-monitoring

# 4. Prepare data directories with correct ownership.
# The Grafana container runs as UID 472 and must be able to write its
# SQLite DB into the mounted data dir, otherwise it crashes on startup with
# "permission denied" creating grafana.db.
mkdir -p /var/lib/prometheus /var/lib/grafana
chown -R 472:472 /var/lib/grafana

# 5. Start the Scylla Monitoring Stack
# -d  : Prometheus data dir
# -G  : Grafana data dir  (NOTE: -b is "Prometheus command line options",
#       NOT the Grafana dir; passing the dir to -b makes Prometheus fail to
#       start with: unknown short flag '-/var/lib/grafana')
# -v ${scylla_version} : load dashboards matching this ScyllaDB version
# --no-loki : skip Loki/promtail. It is not needed for benchmarking and on a
#       small monitoring instance its slow startup trips start-all.sh's 30s
#       readiness probe, which then aborts before launching Prometheus/Grafana.
echo "Launching Prometheus & Grafana containers..."
./start-all.sh -d /var/lib/prometheus -G /var/lib/grafana -v ${scylla_version} --no-loki

echo "========================================="
echo " Monitoring Stack fully active on port 3000!"
echo "========================================="
