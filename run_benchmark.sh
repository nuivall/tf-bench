#!/bin/bash
# Local ScyllaDB Benchmarking Orchestrator (runs on YOUR machine).
#
# Queries Terraform for Scylla private IPs and ALL loader public IPs, then fans
# out over SSH to every loader IN PARALLEL, assigning each a role. Traffic and
# storm are run by SEPARATE loader fleets (no overlap):
#
#   * TRAFFIC loaders (STEADY_LOADERS, default 2) run ONLY the steady-state
#     50/50 mixed load with a PERSISTENT connection pool. This drives the Scylla
#     reactor toward ~80% CPU while producing ZERO new connections/s once ramped.
#     They do NOT participate in the connection storm.
#   * STORM loaders (all remaining loaders) run ONLY the connection storm, which
#     (after --flood-delay) spikes new-connections/s. They do NOT run traffic.
#
# Keeping the two fleets separate isolates the storm's new-connection signal
# from the steady traffic's request load.
#
# Loader #0 additionally (re)creates the schema and pre-populates data before
# the timed phases begin.
#
# Usage:
#   ./run_benchmark.sh [--duration 5m] [--flood-delay 120s] [--flood-duration 180s]
#                      [--steady-loaders 2] [--storm-rate 1000] [--storm-hold 2s]
#                      [--threads 8] [--concurrency 64] [--steady-rate 36000]
#                      [--connections N] [--user cassandra] [--password cassandra]
#                      [--snapshot] [--snapshot-dir ./snapshots]
#
# --steady-rate is the TOTAL steady ops/s across all steady loaders (latte --rate,
# the precise throughput throttle). --concurrency only CAPS in-flight requests and
# does NOT limit throughput on cheap cache-hit reads. Press Ctrl-C to abort: the
# orchestrator stops the local SSH sessions AND signals latte/connect_storm on
# every loader to stop.
set -e

TF_DIR="terraform"
KEY_FILE="terraform/tf-scylla-benchmark-key.pem"

# ---- Defaults ----------------------------------------------------------------
DURATION="5m"           # steady-state length = 2m warm-up baseline + 3m overlapping
                        # the connection storm, so the steady load spans the storm.
FLOOD_DELAY="120s"      # 2m warm-up: steady load establishes a clean baseline
                        # before the storm fires.
FLOOD_DURATION="180s"   # storm length: 3m (fires at 2m, ends at 5m).
STEADY_LOADERS="2"      # how many loaders run the steady ~80% traffic (rest = storm)
STORM_RATE="1000"       # storm: new CQL sessions/s PER storm loader. With the
                        # default 10 storm loaders this targets ~10,000 new
                        # sessions/s aggregate (server-side new-connections/s is
                        # several x higher due to shard-aware pooling).
STORM_HOLD="2s"         # storm: how long each session is held before closing
THREADS="8"
CONCURRENCY="64"       # steady-load in-flight request CAP per thread (latte -p).
                       # This does NOT throttle throughput (with cheap cache-hit
                       # reads latte runs as-fast-as-possible up to this cap); use
                       # --steady-rate to actually set ops/s.
STEADY_RATE="36000"    # TOTAL target ops/s across all steady loaders (latte -r,
                       # closed-loop rate limit). ~36k total => ~18k reads + ~18k
                       # writes. This is the real throughput knob. 0 = unthrottled.
CONNECTIONS=""         # steady-load connections per shard (latte -c); blank=default
SCYLLA_USER="cassandra"     # CQL auth user (cluster runs PasswordAuthenticator)
SCYLLA_PASSWORD="cassandra" # CQL auth password
SNAPSHOT="0"           # if 1, download a Prometheus snapshot after the run
SNAPSHOT_DIR="./snapshots"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -d|--duration)       DURATION="$2"; shift 2 ;;
        --flood-delay)       FLOOD_DELAY="$2"; shift 2 ;;
        --flood-duration)    FLOOD_DURATION="$2"; shift 2 ;;
        --steady-loaders)    STEADY_LOADERS="$2"; shift 2 ;;
        --storm-rate)        STORM_RATE="$2"; shift 2 ;;
        --storm-hold)        STORM_HOLD="$2"; shift 2 ;;
        --threads)           THREADS="$2"; shift 2 ;;
        --concurrency)       CONCURRENCY="$2"; shift 2 ;;
        --steady-rate)       STEADY_RATE="$2"; shift 2 ;;
        --connections)       CONNECTIONS="$2"; shift 2 ;;
        --user)              SCYLLA_USER="$2"; shift 2 ;;
        --password)          SCYLLA_PASSWORD="$2"; shift 2 ;;
        --snapshot)          SNAPSHOT="1"; shift ;;
        --snapshot-dir)      SNAPSHOT_DIR="$2"; SNAPSHOT="1"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [ ! -d "$TF_DIR" ]; then
    echo "Error: 'terraform' directory not found. Run from the project root."
    exit 1
fi

echo "========================================================================="
echo "               SCYLLA AUTOMATED MULTI-AZ BENCHMARK INITIALIZER"
echo "========================================================================="

if ! terraform -chdir="$TF_DIR" output > /dev/null 2>&1; then
    echo "Error: No active Terraform state. Run 'terraform apply' first."
    exit 1
fi

echo "Querying cluster details from Terraform state..."
SCYLLA_IPS=$(terraform -chdir="$TF_DIR" output -json scylla_node_private_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
mapfile -t LOADER_ARRAY < <(terraform -chdir="$TF_DIR" output -json loader_node_public_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
MONITOR_IP=$(terraform -chdir="$TF_DIR" output -raw monitoring_node_public_ip 2>/dev/null || true)

NUM_LOADERS=${#LOADER_ARRAY[@]}
if [ -z "$SCYLLA_IPS" ] || [ "$NUM_LOADERS" -lt 1 ]; then
    echo "Error: Could not retrieve IPs from Terraform output."
    exit 1
fi
[ "$STEADY_LOADERS" -gt "$NUM_LOADERS" ] && STEADY_LOADERS="$NUM_LOADERS"
STORM_LOADERS=$((NUM_LOADERS - STEADY_LOADERS))

# Split the TOTAL target ops/s (STEADY_RATE) evenly across the steady loaders, so
# each loader gets --rate (PER_LOADER_RATE) and the cluster sees ~STEADY_RATE
# total. 0 (or empty) means unthrottled (latte runs as fast as possible).
PER_LOADER_RATE="0"
if [ -n "$STEADY_RATE" ] && [ "$STEADY_RATE" -gt 0 ] 2>/dev/null && [ "$STEADY_LOADERS" -gt 0 ]; then
    PER_LOADER_RATE=$(( STEADY_RATE / STEADY_LOADERS ))
fi

echo "Scylla Private IPs : $SCYLLA_IPS"
echo "Loader fleet       : $NUM_LOADERS nodes"
echo "Traffic-only nodes : $STEADY_LOADERS  (role=load, steady load, 0 new conns)"
echo "Storm-only nodes   : $STORM_LOADERS  (role=flood, connection storm only)"
echo "Steady duration    : $DURATION"
if [ "$PER_LOADER_RATE" -gt 0 ] 2>/dev/null; then
    echo "Steady throughput  : ~${STEADY_RATE} total ops/s  (${PER_LOADER_RATE}/s per steady loader, latte --rate)"
else
    echo "Steady throughput  : UNTHROTTLED (as fast as possible)"
fi
echo "CQL auth user      : $SCYLLA_USER (PasswordAuthenticator)"
echo "Storm              : starts +$FLOOD_DELAY, lasts $FLOOD_DURATION, rate=${STORM_RATE}/s/loader, hold=$STORM_HOLD (separate fleet)"
[ -n "$MONITOR_IP" ] && echo "Grafana Dashboard  : http://$MONITOR_IP:3000"
echo "========================================================================="

if [ "$STORM_LOADERS" -lt 1 ]; then
    echo "WARNING: STEADY_LOADERS ($STEADY_LOADERS) uses the entire fleet of $NUM_LOADERS loaders;"
    echo "         there are NO storm-only loaders left. Reduce --steady-loaders to run a"
    echo "         connection storm, or add more loaders. Continuing with traffic only."
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "Error: SSH private key not found at $KEY_FILE"
    exit 1
fi

SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20)

# ---- Ctrl-C / termination handling -------------------------------------------
# On INT/TERM we must stop BOTH the local SSH children AND the remote workloads
# they launched (otherwise latte / connect_storm keep hammering the cluster after
# the orchestrator exits). The trap kills the local ssh PIDs, then fans out a
# best-effort remote pkill to every loader in parallel, and exits non-zero.
PIDS=()
ABORTING=0
cleanup_and_exit() {
    # Guard against re-entrancy (double Ctrl-C).
    [ "$ABORTING" = "1" ] && return
    ABORTING=1
    echo ""
    echo "========================================================================="
    echo " Ctrl-C received — stopping local SSH sessions and remote workloads..."
    echo "========================================================================="
    # Kill the local ssh child processes (closes the channels).
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null
    done
    # Best-effort: kill latte + the storm binary + the remote runner on every
    # loader, in parallel, with a short connect timeout so we never hang here.
    if [ "${#LOADER_ARRAY[@]}" -gt 0 ]; then
        for ip in "${LOADER_ARRAY[@]}"; do
            ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 ubuntu@"$ip" \
                "pkill -TERM -f 'workloads/run_benchmark.sh' 2>/dev/null; \
                 pkill -TERM -x latte 2>/dev/null; \
                 pkill -TERM -x connect_storm 2>/dev/null; true" >/dev/null 2>&1 &
        done
        wait || true
    fi
    echo " Aborted. Remote workloads signalled to stop."
    [ -n "${MONITOR_IP:-}" ] && echo " View metrics: http://$MONITOR_IP:3000"
    exit 130
}
trap cleanup_and_exit INT TERM

# ---- 1. Sync latest workload files to every loader (in parallel) -------------
# Ships the workload script, the per-loader runner, and the PREBUILT connection-
# storm binary (connect_storm). The binary is copied as-is (no build/toolchain on
# the loader) and made executable. The Rust source dir (connect_storm_rs/) is
# intentionally NOT synced. Fail loudly if the binary is missing.
echo "Synchronizing benchmark files to all $NUM_LOADERS loaders..."
if [ ! -x workloads/connect_storm ]; then
    echo "ERROR: prebuilt storm binary 'workloads/connect_storm' not found or not executable." >&2
    echo "       Build it with: (cd workloads/connect_storm_rs && cargo build --release && \\" >&2
    echo "                        strip target/release/connect_storm && \\" >&2
    echo "                        cp target/release/connect_storm ../connect_storm)" >&2
    exit 1
fi
for ip in "${LOADER_ARRAY[@]}"; do
    (
        scp "${SSH_OPTS[@]}" \
            workloads/workload.rn \
            workloads/run_benchmark.sh \
            workloads/connect_storm \
            ubuntu@"$ip":/home/ubuntu/workloads/ >/dev/null 2>&1
        ssh "${SSH_OPTS[@]}" ubuntu@"$ip" \
            "chmod +x /home/ubuntu/workloads/run_benchmark.sh /home/ubuntu/workloads/connect_storm" >/dev/null 2>&1
    ) &
done
wait
echo "Sync complete."

# ---- 2. Schema + data load on loader #0 (blocking, before timed phases) ------
LOADER0="${LOADER_ARRAY[0]}"
echo "Preparing schema + loading data on loader #0 ($LOADER0)..."
ssh "${SSH_OPTS[@]}" ubuntu@"$LOADER0" \
    "/home/ubuntu/workloads/run_benchmark.sh --role load --schema \
        --duration 1s --flood-delay 0s --flood-duration 0s \
        --user '$SCYLLA_USER' --password '$SCYLLA_PASSWORD' \
        $SCYLLA_IPS" 2>&1 | sed "s/^/  [loader0-prep] /" || true
echo "Schema + data load done."

# ---- 3. Launch all loaders in parallel with their assigned roles -------------
echo "========================================================================="
echo " Launching workload across $NUM_LOADERS loaders (Ctrl+C to abort)..."
echo "========================================================================="
PIDS=()
for idx in "${!LOADER_ARRAY[@]}"; do
    ip="${LOADER_ARRAY[$idx]}"
    if [ "$idx" -lt "$STEADY_LOADERS" ]; then
        ROLE="load"      # traffic only (steady load, NO storm)
    else
        ROLE="flood"     # storm only (NO traffic)
    fi
    CONN_FLAG=""
    [ -n "$CONNECTIONS" ] && CONN_FLAG="--connections $CONNECTIONS"

    (
        # -tt allocates a remote PTY so that if this ssh is killed (Ctrl-C), the
        # remote process tree receives SIGHUP and dies too — a safety net on top
        # of the explicit remote pkill in cleanup_and_exit.
        ssh -tt "${SSH_OPTS[@]}" ubuntu@"$ip" \
            "/home/ubuntu/workloads/run_benchmark.sh \
                --role $ROLE \
                --duration $DURATION \
                --flood-delay $FLOOD_DELAY \
                --flood-duration $FLOOD_DURATION \
                --storm-rate $STORM_RATE --storm-hold $STORM_HOLD \
                --threads $THREADS --concurrency $CONCURRENCY --rate $PER_LOADER_RATE $CONN_FLAG \
                --user '$SCYLLA_USER' --password '$SCYLLA_PASSWORD' \
                $SCYLLA_IPS" 2>&1 | sed "s/^/  [loader$idx:$ROLE] /"
    ) &
    PIDS+=($!)
done

# Wait for all loaders to finish their phases.
FAIL=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=1
done

echo "========================================================================="
if [ "$FAIL" -eq 0 ]; then
    echo " Benchmark Run Complete on all $NUM_LOADERS loaders!"
else
    echo " Benchmark finished with errors on at least one loader (see logs above)."
fi
[ -n "$MONITOR_IP" ] && echo " View metrics: http://$MONITOR_IP:3000"
echo "========================================================================="

# ---- 4. Optionally download a Prometheus monitoring snapshot -----------------
if [ "$SNAPSHOT" = "1" ]; then
    echo ""
    echo "Downloading monitoring snapshot..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$SCRIPT_DIR/fetch_snapshot.sh" ]; then
        "$SCRIPT_DIR/fetch_snapshot.sh" --out-dir "$SNAPSHOT_DIR" \
            || echo "WARNING: snapshot download failed."
    else
        echo "WARNING: $SCRIPT_DIR/fetch_snapshot.sh not found or not executable; skipping snapshot."
    fi
fi
