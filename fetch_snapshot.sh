#!/bin/bash
# Fetch a ScyllaDB monitoring snapshot (Prometheus TSDB) from the monitoring node.
#
# This queries Terraform for the monitoring node's public IP, then SSHes in and
# packages the Prometheus data directory (/var/lib/prometheus, which contains the
# TSDB blocks, the WAL, and the scylla.txt version marker written by start-all.sh)
# into a single tarball, and downloads + extracts it locally.
#
# The resulting directory can be loaded OFFLINE into a local Scylla Monitoring
# stack with:
#
#   cd /code/scylladb/scylla-monitoring
#   ./start-all.sh --archive <extracted_prometheus_data_dir>
#
# The archive mode disables retention (infinite), skips Loki/Alertmanager, and
# reads the ScyllaDB version from scylla.txt automatically.
#
# Capture method: to get a consistent copy we gracefully STOP the Prometheus
# container (SIGTERM flushes the head block + WAL to disk), tar the on-disk data
# directory, then START the container again. The container is only stopped, never
# removed, so the same bind-mounts and flags are preserved on restart.
#
# Usage:
#   ./fetch_snapshot.sh [--out-dir ./snapshots] [--data-dir /var/lib/prometheus]
#                       [--prom-container aprom] [--no-restart]
#
# On success it prints the local path of the extracted data dir and the exact
# start-all.sh command to load it.
set -euo pipefail

TF_DIR="terraform"
KEY_FILE="terraform/tf-scylla-benchmark-key.pem"

OUT_DIR="./snapshots"
REMOTE_DATA_DIR="/var/lib/prometheus"
PROM_CONTAINER="aprom"
RESTART_AFTER="1"        # restart Prometheus after tarring (0 = leave stopped)
REMOTE_TARBALL="/tmp/prometheus_snapshot.$$.tar.gz"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --out-dir)        OUT_DIR="$2"; shift 2 ;;
        --data-dir)       REMOTE_DATA_DIR="$2"; shift 2 ;;
        --prom-container) PROM_CONTAINER="$2"; shift 2 ;;
        --no-restart)     RESTART_AFTER="0"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$TF_DIR" ]; then
    echo "Error: 'terraform' directory not found. Run from the project root." >&2
    exit 1
fi
if [ ! -f "$KEY_FILE" ]; then
    echo "Error: SSH private key not found at $KEY_FILE" >&2
    exit 1
fi

echo "Querying monitoring node IP from Terraform state..." >&2
MONITOR_IP="$(terraform -chdir="$TF_DIR" output -raw monitoring_node_public_ip 2>/dev/null || true)"
if [ -z "$MONITOR_IP" ]; then
    echo "Error: could not determine monitoring_node_public_ip from Terraform output." >&2
    echo "       Is the infrastructure applied?" >&2
    exit 1
fi

SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20)

TS="$(date +%Y%m%d_%H%M%S)"
DEST_DIR="${OUT_DIR%/}/${TS}"
LOCAL_TARBALL="${DEST_DIR}/prometheus_snapshot.tar.gz"
LOCAL_DATA_DIR="${DEST_DIR}/prometheus_data"
mkdir -p "$DEST_DIR"

{
echo "========================================================================="
echo " Capturing Prometheus snapshot from monitoring node $MONITOR_IP"
echo "   remote data dir : $REMOTE_DATA_DIR"
echo "   prom container  : $PROM_CONTAINER"
echo "   local dest      : $DEST_DIR"
echo "========================================================================="
} >&2

# --- 1. Package the Prometheus data dir on the monitoring node ----------------
# Runs remotely. Gracefully stops Prometheus, tars the data dir (as root, since
# the container writes as its own uid), then restarts it unless --no-restart.
# Remote stdout is routed to our stderr so this script's stdout stays clean
# (only the final absolute data-dir path is emitted on stdout).
ssh "${SSH_OPTS[@]}" ubuntu@"$MONITOR_IP" \
    "REMOTE_DATA_DIR='$REMOTE_DATA_DIR' PROM_CONTAINER='$PROM_CONTAINER' \
     REMOTE_TARBALL='$REMOTE_TARBALL' RESTART_AFTER='$RESTART_AFTER' bash -s" <<'REMOTE' >&2
set -euo pipefail
echo "[monitor] Gracefully stopping Prometheus container '$PROM_CONTAINER'..."
if sudo docker ps --format '{{.Names}}' | grep -qx "$PROM_CONTAINER"; then
    # SIGTERM lets Prometheus flush the head block + WAL cleanly (default 120s grace).
    sudo docker stop -t 120 "$PROM_CONTAINER" >/dev/null
    STOPPED=1
else
    echo "[monitor] WARNING: container '$PROM_CONTAINER' not running; tarring current on-disk data."
    STOPPED=0
fi

if [ ! -d "$REMOTE_DATA_DIR" ]; then
    echo "[monitor] ERROR: data dir '$REMOTE_DATA_DIR' does not exist." >&2
    exit 1
fi

echo "[monitor] Archiving $REMOTE_DATA_DIR -> $REMOTE_TARBALL ..."
# -C into the data dir and tar '.' so the archive expands to a flat data dir.
sudo tar czf "$REMOTE_TARBALL" -C "$REMOTE_DATA_DIR" .
sudo chown "$(id -u):$(id -g)" "$REMOTE_TARBALL"
echo "[monitor] Archive size: $(du -h "$REMOTE_TARBALL" | cut -f1)"

if [ "$STOPPED" = "1" ] && [ "$RESTART_AFTER" = "1" ]; then
    echo "[monitor] Restarting Prometheus container '$PROM_CONTAINER'..."
    sudo docker start "$PROM_CONTAINER" >/dev/null
fi
echo "[monitor] Snapshot packaging complete."
REMOTE

# --- 2. Download the tarball --------------------------------------------------
echo "Downloading snapshot to $LOCAL_TARBALL ..." >&2
scp "${SSH_OPTS[@]}" ubuntu@"$MONITOR_IP":"$REMOTE_TARBALL" "$LOCAL_TARBALL" >&2

# --- 3. Clean up the remote tarball ------------------------------------------
ssh "${SSH_OPTS[@]}" ubuntu@"$MONITOR_IP" "rm -f '$REMOTE_TARBALL'" >&2 2>&1 || true

# --- 4. Extract locally -------------------------------------------------------
echo "Extracting snapshot into $LOCAL_DATA_DIR ..." >&2
mkdir -p "$LOCAL_DATA_DIR"
tar xzf "$LOCAL_TARBALL" -C "$LOCAL_DATA_DIR"

# Copy workload_timestamps.json if available in current dir or script dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "workload_timestamps.json" ]; then
    echo "Copying workload_timestamps.json into snapshot folder ..." >&2
    cp "workload_timestamps.json" "$DEST_DIR/"
elif [ -f "$SCRIPT_DIR/workload_timestamps.json" ]; then
    echo "Copying workload_timestamps.json into snapshot folder ..." >&2
    cp "$SCRIPT_DIR/workload_timestamps.json" "$DEST_DIR/"
fi

# Resolve an absolute path for the load instructions.
ABS_DATA_DIR="$(cd "$LOCAL_DATA_DIR" && pwd)"

{
echo "========================================================================="
echo " Snapshot downloaded and extracted."
echo "   tarball    : $LOCAL_TARBALL"
echo "   data dir   : $ABS_DATA_DIR"
echo ""
echo " Load it locally with the Scylla Monitoring stack:"
echo "   cd /code/scylladb/scylla-monitoring"
echo "   ./start-all.sh --archive '$ABS_DATA_DIR'"
echo "========================================================================="
} >&2

# Emit the absolute data dir on the last line of STDOUT for programmatic callers.
echo "$ABS_DATA_DIR"
