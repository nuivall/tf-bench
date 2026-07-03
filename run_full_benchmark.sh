#!/bin/bash
# End-to-end ScyllaDB benchmark pipeline (runs on YOUR machine).
#
# One command to:
#   1. terraform apply        — provision the cluster, loaders, and monitoring node
#   2. wait for boot          — poll until loaders + monitoring are ready
#   3. run the benchmark      — ./run_benchmark.sh (traffic + connection storm)
#   4. fetch the snapshot     — ./fetch_snapshot.sh (Prometheus TSDB tarball)
#   5. load snapshot locally  — start the Scylla Monitoring stack in --archive mode
#                               against the downloaded data so you can browse the
#                               dashboards FAST (done before teardown so metrics
#                               are visible as soon as possible). Also (re)creates
#                               the custom benchmark dashboard via
#                               make_bench_dashboard.py, since the stack restart
#                               wipes any previously-uploaded one.
#   6. terraform destroy      — ALWAYS torn down, even if earlier steps failed.
#
# Teardown is unconditional: destroy runs from a trap so the AWS resources are
# never left running, regardless of benchmark or snapshot outcome. Because the
# local load now runs BEFORE destroy, the cluster stays up slightly longer (until
# you have the offline dashboards), then is torn down.
#
# Usage:
#   ./run_full_benchmark.sh [--monitoring-dir /code/scylladb/scylla-monitoring]
#                           [--snapshot-dir ./snapshots]
#                           [--tf-var 'trusted_cidr=1.2.3.4/32']   (repeatable)
#                           [--boot-timeout 900] [--no-monitoring-snapshot-load]
#                           [--storm-only]
#                           [-- <args passed through to run_benchmark.sh>]
#
# --storm-only runs a connection-storm-only benchmark (no schema, no data load,
# no steady traffic; every loader storms). It simply forwards --storm-only to
# run_benchmark.sh.
#
# --no-monitoring-snapshot-load skips the FINAL step of loading the captured
# Prometheus snapshot into the LOCAL Scylla Monitoring stack. It only affects
# post-run local visualization and is unrelated to --storm-only (the two are
# independent and may be combined).
#
# Everything after a literal `--` is forwarded verbatim to ./run_benchmark.sh,
# e.g.:
#   ./run_full_benchmark.sh -- --duration 3m --steady-loaders 3 --storm-concurrency-per-shard 20
set -u

TF_DIR="terraform"
KEY_FILE="terraform/tf-scylla-benchmark-key.pem"

MONITORING_DIR="/code/scylladb/scylla-monitoring"
SNAPSHOT_DIR="./snapshots"
BOOT_TIMEOUT="900"       # seconds to wait for instances to finish provisioning
DO_LOAD="1"              # load the monitoring snapshot into the LOCAL stack at the end
STORM_ONLY="0"           # if 1, forward --storm-only to run_benchmark.sh (storm-only)
TF_VARS=()               # extra -var arguments for terraform
BENCH_ARGS=()            # forwarded to run_benchmark.sh

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --monitoring-dir) MONITORING_DIR="$2"; shift 2 ;;
        --snapshot-dir)   SNAPSHOT_DIR="$2"; shift 2 ;;
        --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2 ;;
        --tf-var)         TF_VARS+=("-var" "$2"); shift 2 ;;
        --no-monitoring-snapshot-load) DO_LOAD="0"; shift ;;
        --storm-only)     STORM_ONLY="1"; shift ;;
        --)               shift; BENCH_ARGS=("$@"); break ;;
        -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
done

# Forward storm-only to the benchmark. Appended AFTER parsing so it survives even
# when `--` supplied an explicit BENCH_ARGS list (which would otherwise replace
# anything set during the loop). Harmless if the user also passed --storm-only
# themselves after `--` (run_benchmark.sh treats the flag idempotently).
[ "$STORM_ONLY" = "1" ] && BENCH_ARGS+=("--storm-only")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$TF_DIR" ]; then
    echo "Error: 'terraform' directory not found. Run from the project root." >&2
    exit 1
fi

SNAPSHOT_DATA_DIR=""     # set once the snapshot is fetched (used by loader step)
DESTROYED="0"
BENCH_PID=""             # pid/pgid of the benchmark (set while step 3 runs)

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

    # Print the precise start/end time frames of the load and storm phases
    if [ -f "$SCRIPT_DIR/workload_timestamps.json" ]; then
        python3 -c '
import json
from datetime import datetime, timezone
try:
    with open("'"$SCRIPT_DIR"'/workload_timestamps.json") as f:
        data = json.load(f)
    
    def fmt_time(epoch):
        if not epoch:
            return "N/A"
        # Convert to local and UTC strings
        dt_utc = datetime.fromtimestamp(epoch, tz=timezone.utc)
        dt_local = datetime.fromtimestamp(epoch)
        fmt_u = "%Y-%m-%d %H:%M:%S UTC"
        fmt_l = "%H:%M:%S Local"
        return f"{dt_utc.strftime(fmt_u)} ({dt_local.strftime(fmt_l)})"

    load_start = data.get("load_start")
    load_end = data.get("load_end")
    storm_start = data.get("storm_start")
    storm_end = data.get("storm_end")
    workload_start = data.get("workload_start")
    workload_end = data.get("workload_end")

    print(f"Start: {fmt_time(workload_start)}")
    print(f"Storm Start: {fmt_time(storm_start)}")
    print(f"End: {fmt_time(workload_end)}")
except Exception as e:
    print("WARNING: could not print time frames:", e)
' || true
    fi

    return "$rc"
}
trap destroy_infra EXIT
# On Ctrl-C/termination, first tear down the benchmark's process group (its
# ticker/watchdog/ssh children) so nothing keeps printing to this terminal, then
# exit — which triggers the EXIT trap and runs terraform destroy.
on_signal() {
    if [ -n "$BENCH_PID" ]; then
        kill -TERM "-$BENCH_PID" 2>/dev/null || true
    fi
    exit 130
}
trap on_signal INT TERM

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
        if ssh "${SSH_OPTS[@]}" ubuntu@"$LOADER0_IP" "command -v latte >/dev/null 2>&1 && test -d /home/ubuntu/workloads" >/dev/null 2>&1; then
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
# Run the benchmark in its OWN process group (setsid) and remember that group's
# id. run_benchmark.sh spawns background helpers (a progress ticker, a watchdog)
# and per-loader ssh pipelines; if we were ever interrupted while it runs, those
# could otherwise be orphaned and keep printing "[progress] elapsed .." to this
# terminal AFTER we've moved on to snapshot + teardown. Killing the whole group
# once the benchmark returns (or if we get signalled) guarantees a clean stop.
setsid "$SCRIPT_DIR/run_benchmark.sh" "${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}" &
BENCH_PID=$!
wait "$BENCH_PID" || BENCH_RC=$?
# Reap any stragglers in the benchmark's process group (ticker/watchdog/ssh).
kill -TERM "-$BENCH_PID" 2>/dev/null || true
BENCH_PID=""
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

# ---- 5. Load the snapshot locally --------------------------------------------
# Done BEFORE teardown so the metrics become visible as fast as possible (the
# snapshot is already on local disk, so the AWS infra isn't needed for this).
# The cluster stays up a bit longer as a result; it is torn down in step 6.
# NOTE: any `exit 1` below still triggers the EXIT trap, which runs destroy — so
# teardown is guaranteed even if the local load fails.
if [ "$DO_LOAD" = "1" ] && [ -n "$SNAPSHOT_DATA_DIR" ]; then
    banner "STEP: load snapshot locally (Scylla Monitoring --archive)"
    if [ ! -x "$MONITORING_DIR/start-all.sh" ]; then
        echo "ERROR: $MONITORING_DIR/start-all.sh not found." >&2
        echo "       Extracted snapshot is at: $SNAPSHOT_DATA_DIR" >&2
        echo "       Load it manually with:  cd <scylla-monitoring> && ./start-all.sh --archive '$SNAPSHOT_DATA_DIR'" >&2
        exit 1
    fi

    # A previous local stack (aprom/agraf/... containers) would make start-all.sh
    # abort with "Some of the monitoring docker instances (aprom) exist". Tear any
    # existing local stack down first. This is best-effort: on a clean machine
    # kill-all.sh simply finds nothing to remove.
    echo "Clearing any existing local monitoring stack (kill-all.sh)..."
    ( cd "$MONITORING_DIR" && ./kill-all.sh >/dev/null 2>&1 ) || true

    echo "Starting local monitoring stack against snapshot:"
    echo "   $MONITORING_DIR/start-all.sh --archive '$SNAPSHOT_DATA_DIR'"
    if ( cd "$MONITORING_DIR" && ./start-all.sh --archive "$SNAPSHOT_DATA_DIR" ); then
        echo ""
        banner "Snapshot loaded — Grafana at http://localhost:3000 (tearing down AWS next)"
        echo "To stop the local stack later:  ( cd '$MONITORING_DIR' && ./kill-all.sh )"

        # (Re)create the benchmark dashboard. The monitoring stack restart above
        # wipes any previously-uploaded custom dashboard, so we push it fresh on
        # every load. Best-effort: a dashboard failure must not fail the pipeline.
        if [ -x "$SCRIPT_DIR/make_bench_dashboard.py" ]; then
            echo "Waiting for Grafana API to become ready..."
            for _ in $(seq 1 30); do
                if curl -sf -o /dev/null http://localhost:3000/api/health 2>/dev/null; then
                    break
                fi
                sleep 2
            done
            echo "Creating benchmark dashboard..."
            # If the run phase timestamps were recorded, pass them to set the default
            # dashboard time window and mark the load / storm phases on all graphs.
            _ts_args=()
            [ -f "$SCRIPT_DIR/workload_timestamps.json" ] && _ts_args=(--timestamps-file "$SCRIPT_DIR/workload_timestamps.json")
            "$SCRIPT_DIR/make_bench_dashboard.py" --grafana-url http://localhost:3000 "${_ts_args[@]+"${_ts_args[@]}"}" \
                || echo "WARNING: benchmark dashboard upload failed (stack is still up)." >&2
        else
            echo "NOTE: $SCRIPT_DIR/make_bench_dashboard.py not found/executable; skipping dashboard." >&2
        fi
    else
        echo ""
        echo "ERROR: the local monitoring stack failed to start." >&2
        echo "       Extracted snapshot is at: $SNAPSHOT_DATA_DIR" >&2
        echo "       Try manually:" >&2
        echo "         cd '$MONITORING_DIR'" >&2
        echo "         ./kill-all.sh" >&2
        echo "         ./start-all.sh --archive '$SNAPSHOT_DATA_DIR'" >&2
        exit 1
    fi
elif [ "$DO_LOAD" = "1" ]; then
    echo "No snapshot was captured; skipping local load."
else
    echo "Local monitoring-snapshot load disabled (--no-monitoring-snapshot-load)."
    [ -n "$SNAPSHOT_DATA_DIR" ] && echo "Snapshot data dir: $SNAPSHOT_DATA_DIR"
fi

# ---- 6. Teardown -------------------------------------------------------------
# Runs AFTER the local load so metrics are up first. The EXIT trap becomes a
# no-op once this completes.
destroy_infra || true
