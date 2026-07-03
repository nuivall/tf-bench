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
#                      [--steady-loaders 2] [--storm-connections-per-shard 100]
#                      [--storm-concurrency-per-shard 10] [--storm-smp 0]
#                      [--threads 8] [--concurrency 64] [--steady-rate 36000]
#                      [--connections N] [--user cassandra] [--password cassandra]
#                      [--storm-only] [--snapshot] [--snapshot-dir ./snapshots]
#
# --storm-only runs a STORM-ONLY benchmark: it skips schema creation, data
# pre-population, and the steady 50/50 load entirely, and puts EVERY loader in
# the connection-storm role. Use it to exercise/iterate on the connection logic
# alone (no latte.bench table or steady traffic required).
#
# --steady-rate is the TOTAL steady ops/s across all steady loaders (latte --rate,
# the precise throughput throttle). --concurrency only CAPS in-flight requests and
# does NOT limit throughput on cheap cache-hit reads. latte runs quietly (progress
# bar off + large sampling period) so only the final report prints, not per-second
# rows. Press Ctrl-C to abort: the orchestrator stops the local SSH sessions AND
# signals latte/perf-cql-raw on every loader to stop.
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
# Connection-storm intensity (ScyllaDB `perf-cql-raw --workload connect`). Each
# storm loader runs one perf-cql-raw process PER Scylla node; in-flight connect
# cycles per process = STORM_CONNECTIONS_PER_SHARD x STORM_CONCURRENCY_PER_SHARD
# x (loader cores). This concurrency saturates the server's per-shard
# uninitialized-connections semaphore (default 8) to trigger
# scylla_transport_connections_shed.
STORM_CONNECTIONS_PER_SHARD="100"
STORM_CONCURRENCY_PER_SHARD="10"
STORM_SMP="0"          # perf-cql-raw --smp per storm process (0 = all loader cores)
THREADS="8"
CONCURRENCY="64"       # steady-load in-flight request CAP per thread (latte -p).
                       # This does NOT throttle throughput (with cheap cache-hit
                       # reads latte runs as-fast-as-possible up to this cap); use
                       # --steady-rate to actually set ops/s.
STEADY_RATE="14000"    # TOTAL target ops/s across all steady loaders (latte -r,
                       # closed-loop rate limit). ~14k total => ~7k reads +
                       # ~7k writes. This is the real throughput knob.
                       # 0 = unthrottled.
CONNECTIONS=""         # steady-load connections per shard (latte -c); blank=default
SCYLLA_USER="cassandra"     # CQL auth user (cluster runs PasswordAuthenticator)
SCYLLA_PASSWORD="cassandra" # CQL auth password
SNAPSHOT="0"           # if 1, download a Prometheus snapshot after the run
SNAPSHOT_DIR="./snapshots"
STORM_ONLY="0"        # if 1, STORM-ONLY mode: skip schema + data pre-population and
                       # the steady 50/50 load entirely; every loader runs the
                       # connection storm. Use this to iterate on connection logic
                       # without needing the latte.bench table or any steady traffic.

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -d|--duration)       DURATION="$2"; shift 2 ;;
        --flood-delay)       FLOOD_DELAY="$2"; shift 2 ;;
        --flood-duration)    FLOOD_DURATION="$2"; shift 2 ;;
        --steady-loaders)    STEADY_LOADERS="$2"; shift 2 ;;
        --storm-connections-per-shard) STORM_CONNECTIONS_PER_SHARD="$2"; shift 2 ;;
        --storm-concurrency-per-shard) STORM_CONCURRENCY_PER_SHARD="$2"; shift 2 ;;
        --storm-smp)         STORM_SMP="$2"; shift 2 ;;
        --storm-only)        STORM_ONLY="1"; shift ;;
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
# In STORM-ONLY mode (--storm-only) there is no steady traffic: force every loader
# into the storm role by zeroing the steady-loader count.
[ "$STORM_ONLY" = "1" ] && STEADY_LOADERS="0"
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
if [ "$STORM_ONLY" = "1" ]; then
    echo "Mode               : STORM-ONLY (--storm-only: no schema, no data load, no steady traffic)"
fi
echo "Traffic-only nodes : $STEADY_LOADERS  (role=load, steady load, 0 new conns)"
echo "Storm-only nodes   : $STORM_LOADERS  (role=flood, connection storm only)"
echo "Steady duration    : $DURATION"
if [ "$PER_LOADER_RATE" -gt 0 ] 2>/dev/null; then
    echo "Steady throughput  : ~${STEADY_RATE} total ops/s  (${PER_LOADER_RATE}/s per steady loader, latte --rate)"
else
    echo "Steady throughput  : UNTHROTTLED (as fast as possible)"
fi
echo "CQL auth user      : $SCYLLA_USER (PasswordAuthenticator)"
echo "Storm              : starts +$FLOOD_DELAY, lasts $FLOOD_DURATION, perf-cql-raw connect (per-node: conns/shard=$STORM_CONNECTIONS_PER_SHARD, conc/shard=$STORM_CONCURRENCY_PER_SHARD), separate fleet"
[ -n "$MONITOR_IP" ] && echo "Grafana Dashboard  : http://$MONITOR_IP:3000"
echo "========================================================================="

if [ "$STORM_LOADERS" -lt 1 ] && [ "$STORM_ONLY" != "1" ]; then
    echo "WARNING: STEADY_LOADERS ($STEADY_LOADERS) uses the entire fleet of $NUM_LOADERS loaders;"
    echo "         there are NO storm-only loaders left. Reduce --steady-loaders to run a"
    echo "         connection storm, or add more loaders. Continuing with traffic only."
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "Error: SSH private key not found at $KEY_FILE"
    exit 1
fi

SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20)

# ---- Progress ticker helpers -------------------------------------------------
# Convert a duration token (e.g. "5m", "120s", "1500ms", or a bare number of
# seconds) into whole seconds.
to_secs() {
    local t="${1:-0}" n
    case "$t" in
        *ms) n="${t%ms}"; awk "BEGIN{printf \"%d\", ($n)/1000}" ;;
        *s)  printf '%d' "${t%s}" 2>/dev/null || echo 0 ;;
        *m)  n="${t%m}"; awk "BEGIN{printf \"%d\", ($n)*60}" ;;
        *h)  n="${t%h}"; awk "BEGIN{printf \"%d\", ($n)*3600}" ;;
        *)   printf '%d' "$t" 2>/dev/null || echo 0 ;;
    esac
}

# mm:ss formatter.
fmt_hms() { local s="$1"; printf '%d:%02d' "$((s/60))" "$((s%60))"; }

# Total expected wall-clock length of the timed phases. The steady load runs for
# DURATION; the storm runs for FLOOD_DELAY+FLOOD_DURATION. The run ends when the
# LONGER of the two finishes. In STORM-ONLY mode there is no steady load, so only
# the storm timeline counts.
_dur_s=$(to_secs "$DURATION")
_storm_s=$(( $(to_secs "$FLOOD_DELAY") + $(to_secs "$FLOOD_DURATION") ))
if [ "$STORM_ONLY" = "1" ]; then
    TOTAL_SECS="$_storm_s"
else
    TOTAL_SECS=$(( _dur_s > _storm_s ? _dur_s : _storm_s ))
fi
[ "$TOTAL_SECS" -lt 1 ] 2>/dev/null && TOTAL_SECS=1

# Background heartbeat: every 30s print elapsed / remaining benchmark time.
PROGRESS_PID=""
progress_ticker() {
    local total="$1" start now elapsed
    start=$(date +%s)
    while :; do
        sleep 30
        now=$(date +%s)
        elapsed=$(( now - start ))
        echo "  [progress] elapsed $(fmt_hms "$elapsed") / $(fmt_hms "$total")"
    done
}

# ---- Ctrl-C / termination handling -------------------------------------------
# On INT/TERM we must stop BOTH the local SSH children AND the remote workloads
# they launched (otherwise latte / perf-cql-raw keep hammering the cluster after
# the orchestrator exits). The trap kills the local ssh PIDs, then fans out a
# best-effort remote pkill to every loader in parallel, and exits non-zero.
PIDS=()
ABORTING=0

# Each loader pipeline is launched via `setsid` (see the workload loop below),
# so its pid is also its process-group id. Signalling the NEGATED pid delivers
# the signal to the whole group — the ssh -tt AND the tail `sed` — which is the
# only reliable way to tear down a wedged `ssh -tt` (a lone `kill <subshell>`
# leaves ssh/sed alive and makes `wait` block forever).
kill_loader_groups() {
    local sig="$1" pid
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] || continue
        kill "-$sig" "-$pid" 2>/dev/null || kill "-$sig" "$pid" 2>/dev/null || true
    done
}

# Reap the local heartbeat + watchdog background jobs. Safe to call repeatedly.
stop_bg_helpers() {
    [ -n "${PROGRESS_PID:-}" ] && { kill "$PROGRESS_PID" 2>/dev/null; PROGRESS_PID=""; }
    [ -n "${WATCHDOG_PID:-}" ] && { kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""; }
}

# Final safety net: whatever path we exit by (normal, error, signal), make sure
# no background helper or loader process group is left writing to the terminal.
# This is what prevents an orphaned "[progress] elapsed .." ticker from
# continuing to print after the parent has moved on to teardown.
final_cleanup() {
    stop_bg_helpers
    kill_loader_groups TERM
}
trap final_cleanup EXIT

cleanup_and_exit() {
    # Guard against re-entrancy (double Ctrl-C).
    [ "$ABORTING" = "1" ] && return
    ABORTING=1
    echo ""
    echo "========================================================================="
    echo " Ctrl-C received — stopping local SSH sessions and remote workloads..."
    echo "========================================================================="
    # Stop the local heartbeat + watchdog first so nothing keeps printing.
    stop_bg_helpers
    # Kill the local ssh child process GROUPS (closes the channels + tail sed).
    kill_loader_groups TERM
    # Best-effort: kill latte + the storm processes (scylla perf-cql-raw) + the
    # remote runner on every loader, and flush the storm's iptables REDIRECT
    # rules, in parallel with a short connect timeout so we never hang here.
    if [ "${#LOADER_ARRAY[@]}" -gt 0 ]; then
        for ip in "${LOADER_ARRAY[@]}"; do
            ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 ubuntu@"$ip" \
                "pkill -TERM -f 'workloads/run_benchmark.sh' 2>/dev/null; \
                 pkill -TERM -x latte 2>/dev/null; \
                 pkill -TERM -f 'perf-cql-raw' 2>/dev/null; \
                 sudo iptables -t nat -F OUTPUT 2>/dev/null; true" >/dev/null 2>&1 &
        done
        wait || true
    fi
    # SIGKILL any loader group that ignored SIGTERM (wedged ssh -tt PTY).
    kill_loader_groups KILL
    echo " Aborted. Remote workloads signalled to stop."
    [ -n "${MONITOR_IP:-}" ] && echo " View metrics: http://$MONITOR_IP:3000"
    exit 130
}
trap cleanup_and_exit INT TERM

# ---- 1. Sync latest workload files to every loader (in parallel) -------------
# Ships the latte workload (workload.rn) and the per-loader runner. The
# connection storm no longer uses a custom binary: it runs ScyllaDB's native
# `scylla perf-cql-raw`, which is installed on each loader from the Scylla apt
# repo at provision time (see loader.sh.tpl). Nothing to build or copy here.
echo "Synchronizing benchmark files to all $NUM_LOADERS loaders..."
for ip in "${LOADER_ARRAY[@]}"; do
    (
        scp "${SSH_OPTS[@]}" \
            workloads/workload.rn \
            workloads/run_benchmark.sh \
            ubuntu@"$ip":/home/ubuntu/workloads/ >/dev/null 2>&1
        ssh "${SSH_OPTS[@]}" ubuntu@"$ip" \
            "chmod +x /home/ubuntu/workloads/run_benchmark.sh" >/dev/null 2>&1
    ) &
done
wait
echo "Sync complete."

# ---- 2. Schema + data load on loader #0 (blocking, before timed phases) ------
# This step creates the schema and pre-populates latte.bench. It is a HARD
# PREREQUISITE: if it fails, the steady loaders would read/write a non-existent
# table and silently generate no benchmark traffic, while the connection storm
# still pins the cluster — producing a run that looks busy but never exercised
# the real load. So abort here rather than continue into a "storm-only" run.
#
# In STORM-ONLY mode (--storm-only) there is no steady load, so this prerequisite is
# skipped entirely: no schema is created and no data is pre-populated.
if [ "$STORM_ONLY" = "1" ]; then
    echo "STORM-ONLY mode (--storm-only): skipping schema + data pre-population."
else
    LOADER0="${LOADER_ARRAY[0]}"
    echo "Preparing schema + loading data on loader #0 ($LOADER0)..."
    if ! ssh "${SSH_OPTS[@]}" ubuntu@"$LOADER0" \
        "/home/ubuntu/workloads/run_benchmark.sh --role load --schema \
            --duration 1s --flood-delay 0s --flood-duration 0s \
            --user '$SCYLLA_USER' --password '$SCYLLA_PASSWORD' \
            $SCYLLA_IPS" 2>&1 | sed "s/^/  [loader0-prep] /"; then
        echo "========================================================================="
        echo " ERROR: schema + data load FAILED on loader #0 ($LOADER0)."
        echo "        The latte keyspace/table was not prepared, so the steady load"
        echo "        would generate no traffic. Aborting BEFORE the connection storm."
        echo "        Inspect the failure with:"
        echo "          ssh -i $KEY_FILE ubuntu@$LOADER0 'tail -n 40 ~/latte-load.log'"
        echo "========================================================================="
        exit 1
    fi
    echo "Schema + data load done."
fi

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

    # Launch each loader's ssh pipeline in its OWN process group (setsid) so we
    # can later signal the ENTIRE tree — the ssh -tt process AND the sed at the
    # tail of the pipe — with a single kill to the negated group id. Recording
    # only the subshell's `$!` is not enough: killing the subshell leaves the
    # `ssh -tt` (which readily wedges on a stuck PTY) and the `sed` alive, so the
    # wait below would block forever and the progress ticker would run past the
    # expected total. `setsid` makes the subshell a group leader whose pid == pgid.
    setsid bash -c '
        # -tt allocates a remote PTY so that if this ssh is killed (Ctrl-C), the
        # remote process tree receives SIGHUP and dies too — a safety net on top
        # of the explicit remote pkill in cleanup_and_exit.
        ssh -tt "$@" 2>&1 | sed "s/^/  ['"loader$idx:$ROLE"'] /"
    ' _ "${SSH_OPTS[@]}" ubuntu@"$ip" \
        "/home/ubuntu/workloads/run_benchmark.sh \
            --role $ROLE \
            --duration $DURATION \
            --flood-delay $FLOOD_DELAY \
            --flood-duration $FLOOD_DURATION \
            --storm-connections-per-shard $STORM_CONNECTIONS_PER_SHARD \
            --storm-concurrency-per-shard $STORM_CONCURRENCY_PER_SHARD \
            --storm-smp $STORM_SMP \
            --threads $THREADS --concurrency $CONCURRENCY --rate $PER_LOADER_RATE $CONN_FLAG \
            --user '$SCYLLA_USER' --password '$SCYLLA_PASSWORD' \
            $SCYLLA_IPS" &
    PIDS+=($!)
done

# Wait for all loaders to finish their phases. A background ticker prints the
# elapsed/remaining benchmark time every 30s while we block here.
progress_ticker "$TOTAL_SECS" &
PROGRESS_PID=$!

# ---- Global watchdog: never let the run hang past a hard cap -----------------
# Even with per-process timeouts on the loaders, a wedged/unkillable remote
# process or a stuck SSH channel could otherwise block the wait loop below
# forever (the symptom: the progress ticker keeps printing past the expected
# total). This watchdog fires a short margin after TOTAL_SECS — just enough to
# cover the loaders' own per-process SIGTERM/SIGKILL grace plus SSH teardown —
# and forcibly stops the remote workloads and local SSH children so the wait
# loop always returns promptly.
WATCHDOG_SECS=$(( TOTAL_SECS + 20 ))
WATCHDOG_PID=""
run_watchdog() {
    sleep "$WATCHDOG_SECS"
    echo "  [watchdog] run exceeded ${WATCHDOG_SECS}s hard cap — force-stopping loaders." >&2
    for ip in "${LOADER_ARRAY[@]}"; do
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 ubuntu@"$ip" \
            "pkill -KILL -f 'perf-cql-raw' 2>/dev/null; \
             pkill -KILL -f 'workloads/run_benchmark.sh' 2>/dev/null; \
             pkill -KILL -x latte 2>/dev/null; \
             sudo iptables -t nat -F OUTPUT 2>/dev/null; true" >/dev/null 2>&1 &
    done
    wait 2>/dev/null || true
    # Close the local ssh channels so the main `wait` loop returns. Signal the
    # whole process GROUP of each loader pipeline: SIGTERM first, then SIGKILL a
    # moment later for any wedged `ssh -tt` that ignored SIGTERM. Killing the
    # group (not just the subshell) is essential — otherwise the ssh/sed survive
    # and the ticker keeps printing past the total.
    kill_loader_groups TERM
    sleep 3
    kill_loader_groups KILL
}
run_watchdog &
WATCHDOG_PID=$!

FAIL=0
for pid in "${PIDS[@]}"; do
    # A loader SSH child that is TERMINATED (SIGTERM=143 / SIGINT=130) during
    # normal end-of-run teardown is NOT a benchmark failure — the storm's own
    # process teardown and the -tt PTY closing can surface as these codes. Only
    # treat a genuine non-signal failure exit as an error.
    rc=0
    wait "$pid" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 143 ] && [ "$rc" -ne 130 ]; then
        FAIL=1
    fi
done

# Workload done — cancel the watchdog and stop the ticker so neither can keep
# running (or printing) after we move on. stop_bg_helpers is idempotent and is
# also wired to the EXIT trap as a final safety net.
_wd="$WATCHDOG_PID"
stop_bg_helpers
wait "$_wd" 2>/dev/null || true

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

# Exit with a normalized status: 0 on a clean run, 1 only if a loader genuinely
# failed (signal-terminated loaders during teardown were already excluded from
# FAIL above). This prevents a stray SIGTERM (143) from a storm loader's SSH
# child from bubbling up as the whole benchmark's exit code.
exit "$FAIL"
