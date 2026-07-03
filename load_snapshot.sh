#!/bin/bash
# Local ScyllaDB Monitoring Snapshot Loader (runs on YOUR machine).
#
# Scans `./snapshots/` for available datasets, allows the user to
# interactively select one via a numbered menu, and launches the local
# Scylla Monitoring Stack in offline archive mode against it. It then
# automatically adjusts the dashboard view range using the matching
# run phase timestamps.
#
# Usage:
#   ./load_snapshot.sh [--monitoring-dir /code/scylladb/scylla-monitoring]
#                      [--snapshots-dir ./snapshots]
#                      [--snapshot-name <folder_name>]
set -euo pipefail

MONITORING_DIR="/code/scylladb/scylla-monitoring"
SNAPSHOTS_DIR="./snapshots"
SELECTED_NAME=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --monitoring-dir) MONITORING_DIR="$2"; shift 2 ;;
        --snapshots-dir)   SNAPSHOTS_DIR="$2"; shift 2 ;;
        --snapshot-name)   SELECTED_NAME="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$SNAPSHOTS_DIR" ]; then
    echo "Error: snapshots directory '$SNAPSHOTS_DIR' does not exist." >&2
    exit 1
fi

# Locate available snapshot folders (must contain a prometheus_data directory)
mapfile -t SNAPS < <(find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

if [ "${#SNAPS[@]}" -lt 1 ]; then
    echo "Error: No snapshots found in '$SNAPSHOTS_DIR'." >&2
    exit 1
fi

SELECTED_PATH=""

if [ -n "$SELECTED_NAME" ]; then
    # Direct selection via CLI flag
    TARGET_PATH="${SNAPSHOTS_DIR%/}/${SELECTED_NAME}"
    if [ -d "$TARGET_PATH" ]; then
        SELECTED_PATH="$TARGET_PATH"
    else
        echo "Error: Specified snapshot folder '$TARGET_PATH' does not exist." >&2
        exit 1
    fi
else
    # Interactive menu selection
    if [ -t 0 ]; then
        echo "========================================================================="
        echo " ScyllaDB Benchmark Monitoring Snapshot Loader"
        echo "========================================================================="
        echo "Select a snapshot to load locally:"
        
        for idx in "${!SNAPS[@]}"; do
            path="${SNAPS[$idx]}"
            name=$(basename "$path")
            if [ -d "$path/prometheus_data" ]; then
                echo "  $(( idx + 1 )))${name:+$'\t'}${name}  [Ready]"
            else
                echo "  $(( idx + 1 )))${name:+$'\t'}${name}  (Missing prometheus_data)"
            fi
        done
        echo "========================================================================="
        
        read -r -p "Enter choice [1-${#SNAPS[@]}, default 1]: " selection
        selection="${selection:-1}"
        
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#SNAPS[@]}" ]; then
            echo "Error: Invalid selection." >&2
            exit 1
        fi
        SELECTED_PATH="${SNAPS[$(( selection - 1 ))]}"
    else
        # Non-interactive fallback: load the newest snapshot
        SELECTED_PATH="${SNAPS[0]}"
    fi
fi

SELECTED_PATH="$(cd "$SELECTED_PATH" && pwd)"
DATA_DIR="${SELECTED_PATH}/prometheus_data"

if [ ! -d "$DATA_DIR" ]; then
    echo "Error: Selected snapshot '$SELECTED_PATH' does not contain a valid 'prometheus_data' directory." >&2
    exit 1
fi

if [ ! -x "$MONITORING_DIR/start-all.sh" ]; then
    echo "Error: local Scylla Monitoring Stack not found/executable at '$MONITORING_DIR'." >&2
    echo "       Please clone it or override the path using --monitoring-dir." >&2
    exit 1
fi

echo ""
echo "========================================================================="
echo " Loading Snapshot: $(basename "$SELECTED_PATH")"
echo "   data dir:  $DATA_DIR"
echo "========================================================================="

# 1. Stop any running local monitoring container stack
echo "Clearing any active monitoring containers (kill-all.sh)..."
( cd "$MONITORING_DIR" && ./kill-all.sh >/dev/null 2>&1 ) || true

# 2. Launch the local monitoring stack in archive mode
echo "Starting local monitoring stack against snapshot..."
if ! ( cd "$MONITORING_DIR" && ./start-all.sh --archive "$DATA_DIR" ); then
    echo "ERROR: failed to start local monitoring stack." >&2
    exit 1
fi

# 3. Wait for Grafana API to boot up
echo "Waiting for Grafana API to become ready..."
GRAFANA_READY=0
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null http://localhost:3000/api/health 2>/dev/null; then
        GRAFANA_READY=1
        break
    fi
    sleep 2
done

if [ "$GRAFANA_READY" -ne 1 ]; then
    echo "WARNING: Grafana API did not become ready in time; skipping dashboard setup." >&2
    exit 0
fi

# 4. Upload dashboard and adjust focus time range
# Search for workload_timestamps.json in the selected snapshot directory first,
# then fallback to the root directory
TIMESTAMPS_FILE=""
if [ -f "$SELECTED_PATH/workload_timestamps.json" ]; then
    TIMESTAMPS_FILE="$SELECTED_PATH/workload_timestamps.json"
elif [ -f "$SCRIPT_DIR/workload_timestamps.json" ]; then
    TIMESTAMPS_FILE="$SCRIPT_DIR/workload_timestamps.json"
fi

_ts_args=()
if [ -f "$TIMESTAMPS_FILE" ]; then
    echo "Found matching run timestamps at: $TIMESTAMPS_FILE"
    _ts_args=(--timestamps-file "$TIMESTAMPS_FILE")
fi

echo "Uploading custom benchmark dashboard..."
if [ -x "$SCRIPT_DIR/make_bench_dashboard.py" ]; then
    "$SCRIPT_DIR/make_bench_dashboard.py" --grafana-url http://localhost:3000 "${_ts_args[@]+"${_ts_args[@]}"}" \
        || echo "WARNING: failed to upload custom dashboard." >&2
else
    echo "WARNING: $SCRIPT_DIR/make_bench_dashboard.py not found or not executable." >&2
fi

echo ""
echo "========================================================================="
echo " Snapshot loaded successfully!"
echo " Open Grafana: http://localhost:3000/d/scylla-benchmark/scylladb-benchmark"
echo "========================================================================="
