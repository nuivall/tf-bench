#!/bin/bash
# ScyllaDB Automated Multi-AZ Benchmark Runner
# This script handles the entire pipeline: schema initialization, loading, starting background connection storm, running mixed load, and cleaning up.
set -e

WORKLOAD_PATH="$HOME/workloads/workload.rn"
STORM_PATH="$HOME/workloads/connect_storm.sh"
DURATION="5m" # Default duration

# Parse optional override for duration
if [ "$1" == "--duration" ] || [ "$1" == "-d" ]; then
    DURATION="$2"
    shift 2
fi

# Determine Scylla IPs
if [ "$#" -lt 1 ]; then
    echo "Error: No Scylla IPs provided."
    echo "Usage: $0 [--duration <duration>] <scylla-node-ip-1> [scylla-node-ip-2] ..."
    exit 1
fi
SCYLLA_IPS="$@"

if [ ! -f "$WORKLOAD_PATH" ]; then
    WORKLOAD_PATH="./workload.rn"
fi
if [ ! -f "$STORM_PATH" ]; then
    STORM_PATH="./connect_storm.sh"
fi

echo "========================================================================="
echo "               SCYLLA AUTOMATED MULTI-AZ BENCHMARK RUNNER"
echo "========================================================================="
echo "Scylla Cluster IPs: $SCYLLA_IPS"
echo "Workload Script:    $WORKLOAD_PATH"
echo "Steady-State Duration: $DURATION"
echo "========================================================================="

echo -e "\n[1/4] Initializing Database Schema (latte schema)..."
latte schema "$WORKLOAD_PATH" $SCYLLA_IPS

echo -e "\n[2/4] Pre-populating 1,000,000 rows (latte load)..."
latte run -f load -d 1000000 --threads 8 --concurrency 64 "$WORKLOAD_PATH" $SCYLLA_IPS

echo -e "\n[3/4] Launching background Connection Storm (delayed by 120s to capture baseline)..."
"$STORM_PATH" $SCYLLA_IPS > /dev/null 2>&1 &
STORM_PID=$!
echo "Connection storm background process started (PID: $STORM_PID)."

echo -e "\n[4/4] Starting steady-state 50/50 Mixed Read/Write load..."
latte run -f read:0.5 -f write:0.5 -d "$DURATION" --threads 8 --concurrency 64 "$WORKLOAD_PATH" $SCYLLA_IPS

echo -e "\n========================================================================="
echo " Steady-state run finished! Shutting down connection storm..."
kill $STORM_PID || true
wait $STORM_PID 2>/dev/null || true
echo " Connection storm stopped successfully."
echo "========================================================================="
echo " Benchmark Run Complete!"
echo " Navigate to your Grafana dashboard (port 3000) to view metrics."
echo "========================================================================="
