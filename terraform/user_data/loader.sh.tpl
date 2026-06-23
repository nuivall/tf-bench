#!/bin/bash
# Latte Loader provisioning with Precompiled Native Binary and Custom Workloads
set -xe

# Redirect stdout/stderr to a log file for debugging
exec > >(tee /var/log/loader-setup.log | logger -t user-data -s 2>/dev/null) 2>&1

echo "========================================="
echo " Starting Latte Loader node provisioning"
echo "========================================="

# 1. Install dependencies
apt-get update && apt-get install -y curl wget git htop iotop build-essential

# 2. Download and install Precompiled Latte Release Binary (v0.49.0-scylladb)
LATTE_VERSION="0.49.0-scylladb"
echo "Downloading precompiled Latte binary..."
wget https://github.com/scylladb/latte/releases/download/$${LATTE_VERSION}/latte-$${LATTE_VERSION}--ubuntu-24.04 -O /usr/local/bin/latte
chmod +x /usr/local/bin/latte

# Verify installation
latte --version

# 3. Create workloads directory for ubuntu user
mkdir -p /home/ubuntu/workloads

# Write workloads/workload.rn to loader
cat <<'EOF' > /home/ubuntu/workloads/workload.rn
${workload_rn_content}
EOF

# Write workloads/connect_storm.sh to loader
cat <<'EOF' > /home/ubuntu/workloads/connect_storm.sh
${connect_storm_content}
EOF

# Make script executable and fix ownership
chmod +x /home/ubuntu/workloads/connect_storm.sh
chown -R ubuntu:ubuntu /home/ubuntu/workloads

echo "========================================="
echo " Loader Node fully provisioned!"
echo "========================================="
