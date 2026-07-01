#!/bin/bash
# End-to-end ScyllaDB benchmark pipeline (runs on YOUR machine).
#
# One command to:
#   1. terraform apply        — provision the cluster, loaders, and monitoring node
#   2. wait for boot          — poll until loaders + monitoring are ready
#   3. run the benchmark      — ./run_benchmark.sh (traffic + connection storm)
#   4. fetch the snapshot     — ./fetch_snapshot.sh (Prometheus TSDB tarball)
#   5. terraform destroy      — ALWAYS torn down, even if earlier steps failed
#   6. load snapshot locally  — start the Scylla Monitoring stack in --archive mode
#                               against the downloaded data so you can browse the
#                               exact dashboards offline after the infra is gone.
#
# Teardown is unconditional: destroy runs from a trap so the AWS resources are
# never left running, regardless of benchmark or snapshot outcome.
#
# Usage:
#   ./run_full_benchmark.sh [--monitoring-dir /code/scylladb/scylla-monitoring]
#                           [--snapshot-dir ./snapshots]
#                           [--tf-var 'trusted_cidr=1.2.3.4/32']   (repeatable)
#                           [--boot-timeout 900] [--no-load]
#                           [-- <args passed through to run_benchmark.sh>]
#
# Everything after a literal `--` is forwarded verbatim to ./run_benchmark.sh,
# e.g.:
#   ./run_full_benchmark.sh -- --duration 3m --steady-loaders 2 --storm-rate 30
set -u

TF_DIR="terraform"
KEY_FILE="terraform/tf-scylla-benchmark-key.pem"

MONITORING_DIR="/code/scylladb/scylla-monitoring"
SNAPSHOT_DIR="./snapshots"
BOOT_TIMEOUT="900"       # seconds to wait for instances to finish provisioning
DO_LOAD="1"              # load the snapshot locally at the end
TF_VARS=()               # extra -var arguments for terraform
BENCH_ARGS=()            # forwarded to run_benchmark.sh

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --monitoring-dir) MONITORING_DIR="$2"; shift 2 ;;
        --snapshot-dir)   SNAPSHOT_DIR="$2"; shift 2 ;;
        --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2 ;;
        --tf-var)         TF_VARS+=("-var" "$2"); shift 2 ;;
        --no-load)        DO_LOAD="0"; shift ;;
        --)               shift; BENCH_ARGS=("$@"); break ;;
        -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$TF_DIR" ]; then
    echo "Error: 'terraform' directory not found. Run from the project root." >&2
    exit 1
fi

SNAPSHOT_DATA_DIR=""     # set once the snapshot is fetched (used by loader step)
DESTROYED="0"

banner() { echo "=========================================================================";
           echo " $*";
           echo "========================================================================="; }

# ---- Unconditional teardown --------------------------------------------------
# Registered as an EXIT trap so `terraform destroy` runs no matter how we leave:
# normal completion, benchmark failure, snapshot failure, or Ctrl-C.
destroy_infra() {
    local rc=$?
    if [ "$DESTROYED" = "1" ]; then
        return
    fi
    DESTROYED="1"
    echo ""
    banner "STEP: terraform destroy (unconditional teardown)"
    if terraform -chdir="$TF_DIR" destroy -auto-approve "${TF_VARS[@]+"${TF_VARS[@]}"}"; then
        echo "Infrastructure destroyed."
    else
        echo "ERROR: terraform destroy failed. CHECK YOUR AWS CONSOLE for leftover resources!" >&2
    fi
    return "$rc"
}
trap destroy_infra EXIT
trap 'exit 130' INT TERM

# ---- 1. terraform apply ------------------------------------------------------
banner "STEP: terraform apply"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
if ! terraform -chdir="$TF_DIR" apply -auto-approve "${TF_VARS[@]+"${TF_VARS[@]}"}"; then
    echo "ERROR: terraform apply failed; aborting (teardown will run)." >&2
    exit 1
fi

# Gather IPs for the readiness probe.
MONITOR_IP="$(terraform -chdir="$TF_DIR" output -raw monitoring_node_public_ip 2>/dev/null || true)"
LOADER0_IP="$(terraform -chdir="$TF_DIR" output -json loader_node_public_ips 2>/dev/null \
                | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"

SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)

# ---- 2. Wait for instances to finish cloud-init provisioning -----------------
banner "STEP: waiting for loaders + monitoring to become ready (timeout ${BOOT_TIMEOUT}s)"
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
loader_ready="0"
monitor_ready="0"
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$loader_ready" != "1" ] && [ -n "$LOADER0_IP" ]; then
        if ssh "${SSH_OPTS[@]}" ubuntu@"$LOADER0_IP" "command -v latte >/dev/null 2>&1 && test -f /home/ubuntu/workloads/connect_storm.py" >/dev/null 2>&1; then
            loader_ready="1"; echo "  loader0 ($LOADER0_IP) ready (latte + workloads present)."
        fi
    fi
    if [ "$monitor_ready" != "1" ] && [ -n "$MONITOR_IP" ]; then
        # Prometheus readiness endpoint on the monitoring node (port 9090).
        if ssh "${SSH_OPTS[@]}" ubuntu@"$MONITOR_IP" "curl -sf -o /dev/null http://localhost:9090/-/ready" >/dev/null 2>&1; then
            monitor_ready="1"; echo "  monitoring ($MONITOR_IP) ready (Prometheus up)."
        fi
    fi
    if [ "$loader_ready" = "1" ] && [ "$monitor_ready" = "1" ]; then
        break
    fi
    sleep 10
done

if [ "$loader_ready" != "1" ]; then
    echo "WARNING: loader0 did not report ready within ${BOOT_TIMEOUT}s; proceeding anyway." >&2
fi
if [ "$monitor_ready" != "1" ]; then
    echo "WARNING: monitoring did not report ready within ${BOOT_TIMEOUT}s; snapshot may be incomplete." >&2
fi

# ---- 3. Run the benchmark ----------------------------------------------------
banner "STEP: run benchmark"
BENCH_RC=0
"$SCRIPT_DIR/run_benchmark.sh" "${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}" || BENCH_RC=$?
[ "$BENCH_RC" -ne 0 ] && echo "WARNING: benchmark exited with code $BENCH_RC; continuing to snapshot + teardown." >&2

# ---- 4. Fetch the monitoring snapshot ----------------------------------------
banner "STEP: fetch monitoring snapshot"
# fetch_snapshot.sh prints the absolute extracted data dir as its LAST stdout line.
if SNAP_OUT="$("$SCRIPT_DIR/fetch_snapshot.sh" --out-dir "$SNAPSHOT_DIR")"; then
    echo "$SNAP_OUT"
    SNAPSHOT_DATA_DIR="$(printf '%s\n' "$SNAP_OUT" | tail -n1)"
    if [ ! -d "$SNAPSHOT_DATA_DIR" ]; then
        echo "WARNING: reported snapshot dir '$SNAPSHOT_DATA_DIR' does not exist." >&2
        SNAPSHOT_DATA_DIR=""
    fi
else
    echo "WARNING: snapshot fetch failed; local load will be skipped." >&2
    SNAPSHOT_DATA_DIR=""
fi

# ---- 5. Teardown -------------------------------------------------------------
# Run destroy explicitly here (and mark done) so it happens BEFORE we block on
# the local monitoring stack. The EXIT trap becomes a no-op afterwards.
destroy_infra || true

# ---- 6. Load the snapshot locally --------------------------------------------
if [ "$DO_LOAD" = "1" ] && [ -n "$SNAPSHOT_DATA_DIR" ]; then
    banner "STEP: load snapshot locally (Scylla Monitoring --archive)"
    if [ ! -x "$MONITORING_DIR/start-all.sh" ]; then
        echo "ERROR: $MONITORING_DIR/start-all.sh not found." >&2
        echo "       Extracted snapshot is at: $SNAPSHOT_DATA_DIR" >&2
        echo "       Load it manually with:  cd <scylla-monitoring> && ./start-all.sh --archive '$SNAPSHOT_DATA_DIR'" >&2
        exit 1
    fi
    echo "Starting local monitoring stack against snapshot:"
    echo "   $MONITORING_DIR/start-all.sh --archive '$SNAPSHOT_DATA_DIR'"
    ( cd "$MONITORING_DIR" && ./start-all.sh --archive "$SNAPSHOT_DATA_DIR" )
    echo ""
    banner "DONE — snapshot loaded. Open Grafana at http://localhost:3000"
    echo "To stop the local stack later:  ( cd '$MONITORING_DIR' && ./kill-all.sh )"
elif [ "$DO_LOAD" = "1" ]; then
    echo "No snapshot was captured; skipping local load."
else
    echo "Local load disabled (--no-load)."
    [ -n "$SNAPSHOT_DATA_DIR" ] && echo "Snapshot data dir: $SNAPSHOT_DATA_DIR"
fi
