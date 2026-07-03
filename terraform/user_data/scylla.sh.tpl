#!/bin/bash
# ScyllaDB multi-AZ node setup with NVMe RAID-0 storage and Precalculated I/O Tuning
set -xe

# Redirect stdout/stderr to a log file for debugging
exec > >(tee /var/log/scylla-setup.log | logger -t user-data -s 2>/dev/null) 2>&1

echo "========================================="
echo " Starting ScyllaDB node provisioning"
echo "========================================="

# 1. Ephemeral NVMe Disk Setup (RAID-0 & XFS formatting)
echo "Detecting NVMe ephemeral disks..."
# Dynamically identify the root block device (e.g. /dev/nvme1n1) to prevent accidental wipes
root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
# Select all NVMe storage disks except the root block device
disks=$(lsblk -dno name | grep -E '^nvme[0-9]' | sed 's|^|/dev/|' | grep -v "$root_dev" || true)
disk_count=$(echo "$disks" | wc -w)

mkdir -p /var/lib/scylla

if [ "$disk_count" -eq 1 ]; then
    echo "Found 1 NVMe ephemeral disk: $disks. Formatting with XFS..."
    mkfs.xfs -f "$disks"
    mount -o noatime,lazytime "$disks" /var/lib/scylla
    echo "$disks /var/lib/scylla xfs noatime,lazytime 0 0" >> /etc/fstab
elif [ "$disk_count" -gt 1 ]; then
    echo "Found $disk_count NVMe ephemeral disks. Assembling RAID-0..."
    apt-get update && apt-get install -y mdadm
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices="$disk_count" $disks
    mkfs.xfs -f /dev/md0
    mount -o noatime,lazytime /dev/md0 /var/lib/scylla
    echo "/dev/md0 /var/lib/scylla xfs noatime,lazytime 0 0" >> /etc/fstab
else
    echo "No NVMe ephemeral storage found (likely testing on non-storage VM). Falling back to root disk..."
fi

# 2. Pre-create configuration directories and inject Precalculated I/O Tuning
echo "Injecting precalculated I/O properties..."
mkdir -p /etc/scylla.d

# Write io_properties.yaml using mapped variables from Terraform
cat <<EOF > /etc/scylla.d/io_properties.yaml
disks:
  - mountpoint: /var/lib/scylla
    read_iops: ${read_iops}
    read_bandwidth: ${read_bandwidth}
    write_iops: ${write_iops}
    write_bandwidth: ${write_bandwidth}
EOF

# Write io.conf to bypass the slow 15-minute iotune benchmark
cat <<EOF > /etc/scylla.d/io.conf
SEASTAR_IO="--io-properties-file=/etc/scylla.d/io_properties.yaml"
EOF

# 3. Add ScyllaDB Repository and Install Scylla
echo "Installing ScyllaDB version ${scylla_version}..."
apt-get update && apt-get install -y curl gupnp-tools apt-transport-https gnupg2

curl -sSfLo /etc/apt/sources.list.d/scylla.list https://s3.amazonaws.com/downloads.scylladb.com/deb/ubuntu/scylla-${scylla_version}.list
# Automatically replace signed-by with trusted=yes to bypass expired 2024 Scylla GPG signatures in 2026
sed -i 's/signed-by=\/etc\/apt\/keyrings\/scylladb.gpg/trusted=yes/g' /etc/apt/sources.list.d/scylla.list

apt-get update
# Force non-interactive installation and keep pre-created io.conf configuration
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" scylla

# 4. System Tuning and Configurations
echo "Running system configurations..."
scylla_sysconfig_setup

# Get Private IP of current machine
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# Overwrite scylla.yaml cluster settings
echo "Configuring scylla.yaml..."
cat <<EOF > /etc/scylla/scylla.yaml
cluster_name: '${cluster_name}'
num_tokens: 256
data_file_directories:
    - /var/lib/scylla/data
commitlog_directory: /var/lib/scylla/commitlog
hints_directory: /var/lib/scylla/hints
view_hints_directory: /var/lib/scylla/view_hints
saved_caches_directory: /var/lib/scylla/saved_caches
seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          - seeds: '${seed_ip}'
listen_address: $PRIVATE_IP
broadcast_address: $PRIVATE_IP
rpc_address: 0.0.0.0
broadcast_rpc_address: $PRIVATE_IP
endpoint_snitch: Ec2Snitch
api_address: 127.0.0.1
developer_mode: false
# ---- Authentication / Authorization ----------------------------------------
# Real username/password auth (PasswordAuthenticator) + role-based permissions
# (CassandraAuthorizer). Clients MUST present valid credentials.
#
# latte authenticates correctly against this: its `--user`/`--password` flags
# work as long as they are passed BEFORE the workload path positional (which the
# benchmark scripts do). NOTE: do NOT use the Transitional* variants here — the
# pinned latte build sends an empty SASL username that trips a server-side bug
# ("plain_sasl_challenge::get_username() called without username") under
# transitional auth, whereas strict PasswordAuthenticator with real credentials
# works cleanly.
authenticator: PasswordAuthenticator
authorizer: CassandraAuthorizer
# Preseed the built-in superuser deterministically so credentials exist from the
# very first boot WITHOUT the usual system_auth RF=1 bootstrap race (which can
# otherwise leave 'cassandra'/'cassandra' temporarily unusable). The salted hash
# below is SHA-512 crypt of the password 'cassandra'. NOTE: the '\$' escapes are
# required so this UNQUOTED heredoc does not shell-expand the '$6'/'$2' segments
# of the crypt hash (which would corrupt it); the shell writes them as literal '$'.
auth_superuser_name: cassandra
auth_superuser_salted_password: '\$6\$x7IFjiX5VCpvNiFk\$2IfjTvSyGL7zerpV.wbY7mJjaRCrJ/68dtT3UpT.sSmNYz1bPjtn3mH.kJKFvaZ2T4SbVeBijjmwGjcb83LlV/'
EOF

# 5. Enable and Start Services
echo "Starting ScyllaDB services..."
systemctl daemon-reload
systemctl enable scylla-server
systemctl restart scylla-server

# 5b. Enable and start the Prometheus node_exporter.
# The scylla-node-exporter package is installed as a dependency of the scylla
# meta-package but ships DISABLED by default. Without it, port 9100 is closed
# and the Scylla Monitoring OS dashboards (CPU, memory, disk, network) stay
# empty / show 0. It listens on 0.0.0.0:9100 by default, which the cluster
# security group already allows within the VPC.
echo "Enabling Prometheus node_exporter for OS-level metrics..."
systemctl enable --now scylla-node-exporter

# 5c. Harden auth availability (SEED NODE ONLY).
# The superuser is preseeded via auth_superuser_salted_password, but the backing
# 'system_auth' keyspace still defaults to RF=1. On a 3-node multi-AZ cluster we
# raise it to RF=3 so credentials/permissions survive a single-node outage.
# We authenticate as the preseeded cassandra/cassandra superuser. Runs on the
# seed only, and retries until CQL + auth are ready.
if [ "$PRIVATE_IP" = "${seed_ip}" ]; then
    echo "[seed] Waiting for CQL auth, then bumping system_auth RF to 3..."
    for i in $(seq 1 60); do
        if cqlsh "$PRIVATE_IP" -u cassandra -p cassandra \
                -e "ALTER KEYSPACE system_auth WITH REPLICATION = {'class':'SimpleStrategy','replication_factor':3};" \
                >/dev/null 2>&1; then
            echo "[seed] system_auth replication set to RF=3."
            nodetool repair -pr system_auth >/dev/null 2>&1 || true
            break
        fi
        echo "[seed] CQL not ready yet (attempt $i/60); retrying in 10s..."
        sleep 10
    done
fi

echo "========================================="
echo " ScyllaDB Node fully provisioned!"
echo "========================================="
