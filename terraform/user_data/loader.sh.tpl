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

# 1a. OS tuning for high new-connection-per-second connection floods.
# A connection storm opens and tears down huge numbers of short-lived TCP+CQL
# sessions. The client side is normally limited first by (a) open file
# descriptors, (b) the ephemeral source-port range, and (c) sockets stuck in
# TIME_WAIT. Widen all three so a single loader can sustain tens of thousands
# of new connections/s.
echo "Applying connection-flood OS tuning..."
cat <<'SYSCTL' > /etc/sysctl.d/99-latte-connflood.conf
# Maximize usable ephemeral source ports (~64k - 1024 = ~64.5k per loader)
net.ipv4.ip_local_port_range = 1024 65535
# Recycle TIME_WAIT sockets quickly so ports free up for new connections
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5
# Larger listen/accept and SYN backlogs
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
# Allow many sockets in TIME_WAIT without dropping them
net.ipv4.tcp_max_tw_buckets = 2000000
SYSCTL
sysctl --system || true

# Raise file-descriptor limits (each open connection consumes one fd).
cat <<'LIMITS' > /etc/security/limits.d/99-latte-nofile.conf
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
LIMITS
# Ensure systemd-launched and interactive shells also get the high limit
echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
mkdir -p /etc/systemd/user.conf.d
echo -e "[Manager]\nDefaultLimitNOFILE=1048576" > /etc/systemd/user.conf.d/nofile.conf

# 2. Download and install Precompiled Latte Release Binary (v0.49.0-scylladb)
LATTE_VERSION="0.49.0-scylladb"
echo "Downloading precompiled Latte binary..."
wget https://github.com/scylladb/latte/releases/download/$${LATTE_VERSION}/latte-$${LATTE_VERSION}--ubuntu-24.04 -O /usr/local/bin/latte
chmod +x /usr/local/bin/latte

# Verify installation
latte --version

# 3. Create workloads directory for ubuntu user
mkdir -p /home/ubuntu/workloads

# The embedded workload files are gzip+base64-compressed (to stay under the
# 16 KB EC2 user_data limit). Decode each back to its original form. NOTE: the
# connection-storm generator is a PREBUILT binary (connect_storm) that is too
# large for user_data; the orchestrator scp's it onto the loader at run time.

# Write workloads/workload.rn to loader
base64 -d <<'EOF' | gunzip > /home/ubuntu/workloads/workload.rn
${workload_rn_content}
EOF

# Write workloads/run_benchmark.sh to loader
base64 -d <<'EOF' | gunzip > /home/ubuntu/workloads/run_benchmark.sh
${run_benchmark_content}
EOF

# Make scripts executable and fix ownership
chmod +x /home/ubuntu/workloads/run_benchmark.sh
chown -R ubuntu:ubuntu /home/ubuntu/workloads

echo "========================================="
echo " Loader Node fully provisioned!"
echo "========================================="
