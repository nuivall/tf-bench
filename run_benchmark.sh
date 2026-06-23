#!/bin/bash
# Local ScyllaDB Benchmarking Orchestrator
# This script automatically queries Terraform outputs for Scylla private IPs and Loader public IPs,
# and triggers the automated remote benchmark script on Loader-0 over SSH.
set -e

TF_DIR="terraform"
KEY_FILE="terraform/tf-scylla-benchmark-key.pem"

if [ ! -d "$TF_DIR" ]; then
    echo "Error: 'terraform' directory not found. Please run this script from the project root."
    exit 1
fi

echo "========================================================================="
echo "               SCYLLA AUTOMATED MULTI-AZ BENCHMARK INITIALIZER"
echo "========================================================================="

# 1. Verify Terraform state exists
if ! terraform -chdir="$TF_DIR" output > /dev/null 2>&1; then
    echo "Error: No active Terraform state found. Please run 'terraform apply' first."
    exit 1
fi

# 2. Query Scylla Node IPs and Loader IPs directly from Terraform outputs
echo "Querying cluster details from Terraform state..."
SCYLLA_IPS=$(terraform -chdir="$TF_DIR" output -json scylla_node_private_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
LOADER_IPS=$(terraform -chdir="$TF_DIR" output -json loader_node_public_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
MONITOR_IP=$(terraform -chdir="$TF_DIR" output -raw monitoring_node_public_ip 2>/dev/null || true)

# Resolve first loader to trigger workload
LOADER_ARRAY=($LOADER_IPS)
FIRST_LOADER="${LOADER_ARRAY[0]}"

if [ -z "$SCYLLA_IPS" ] || [ -z "$FIRST_LOADER" ]; then
    echo "Error: Could not retrieve IPs from Terraform output."
    exit 1
fi

# 3. Handle optional duration override (e.g. --duration 10m)
DURATION=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--duration) DURATION="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

REMOTE_CMD="./workloads/run_benchmark.sh"
if [ ! -z "$DURATION" ]; then
    REMOTE_CMD="$REMOTE_CMD --duration $DURATION"
fi
REMOTE_CMD="$REMOTE_CMD $SCYLLA_IPS"

echo "Scylla Private IPs:   $SCYLLA_IPS"
echo "Target Loader Node:   $FIRST_LOADER"
if [ ! -z "$MONITOR_IP" ]; then
    echo "Grafana Dashboard:    http://$MONITOR_IP:3000"
fi
echo "========================================================================="

# Verify active private SSH key file exists
if [ ! -f "$KEY_FILE" ]; then
    echo "Error: SSH private key not found at $KEY_FILE"
    exit 1
fi

# 4. Trigger the remote execution on Loader-0 over SSH
echo "Connecting to Loader-0 over SSH and starting the automated benchmark..."
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$FIRST_LOADER" "$REMOTE_CMD"
