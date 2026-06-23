#!/bin/bash
# Connection Storm Generator for ScyllaDB using Latte
# This script launches parallel short-lived Latte commands to stress coordinator connections.

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <scylla-node-ip-1> [scylla-node-ip-2] ..."
    exit 1
fi
NODES="$@"
WORKLOAD_PATH="$HOME/workloads/workload.rn"

if [ ! -f "$WORKLOAD_PATH" ]; then
    # Fallback to local directory if not found in home workloads folder
    WORKLOAD_PATH="./workload.rn"
fi

echo "========================================================================="
echo " WARNING: Starting connection storm against nodes: $NODES"
echo " Spawning parallel transient connection sessions..."
echo " Press [CTRL+C] to stop."
echo "========================================================================="

while true; do
    # Spawn 5 parallel Latte runs in the background.
    # Each run has 10 threads and 50 concurrency = 500 connections per run.
    # 5 parallel runs * 500 connections = 2,500 rapid connection establishments.
    for i in {1..5}; do
        latte run -f read -d 1s --threads 10 --concurrency 50 "$WORKLOAD_PATH" $NODES > /dev/null 2>&1 &
    done
    
    # Wait for the transient sessions to finish and disconnect, then repeat
    sleep 1.2
done
