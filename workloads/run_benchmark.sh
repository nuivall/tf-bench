#!/bin/bash
# ScyllaDB per-loader benchmark runner (runs ON A SINGLE LOADER).
#
# The local orchestrator (project-root run_benchmark.sh) invokes this on every
# loader in parallel and passes a ROLE so each loader does the right thing:
#
#   --role load    : steady-state 50/50 mixed read/write using a PERSISTENT
#                    connection pool. After the initial ramp this produces
#                    ZERO new connections/s (the pool is reused). This is the
#                    "traffic" role and does NOT run the connection storm.
#   --role flood   : sits idle for FLOOD_DELAY, then runs the connection storm
#                    (the prebuilt `connect_storm` binary) for FLOOD_DURATION.
#                    No steady traffic. This is the "storm" role.
#   --role both    : runs steady load AND, after FLOOD_DELAY, overlaps the
#                    connection storm on top of it for FLOOD_DURATION. Kept for
#                    flexibility; the orchestrator no longer assigns it so that
#                    traffic and storm loaders stay cleanly separated.
#
# Phase banners are printed for BOTH the load and the storm so the log clearly
# shows what is happening at each moment.
#
# Usage:
#   run_benchmark.sh --role <load|flood|both> \
#                    [--duration 5m] [--flood-delay 120s] [--flood-duration 180s] \
#                    [--storm-rate 1000] [--storm-hold 2s] \
#                    [--threads N] [--concurrency N] [--rate OPS_PER_SEC] \
#                    [--connections N] [--user cassandra] [--password cassandra] \
#                    <scylla-ip-1> [scylla-ip-2 ...]
#
# --rate is this loader's steady throughput in ops/s (latte -r). --concurrency is
# only the in-flight cap. latte runs quietly: -q hides the progress bar and a
# large -s/--sampling period suppresses the per-second statistics rows, so only
# phase banners, storm logs, and the final report are printed.
set -u

ROLE="both"
DURATION="5m"           # steady-state length (2m warm-up + 3m overlapping the storm)
FLOOD_DELAY="120s"      # 2m warm-up baseline before the storm fires
FLOOD_DURATION="180s"   # how long the storm lasts (3m)
STORM_RATE="1000"       # storm: new CQL sessions opened per second (steepness).
                        # x10 storm loaders -> ~10,000 sessions/s aggregate.
STORM_HOLD="2s"         # storm: how long each session is held before closing
THREADS="8"             # steady-load latte -t
CONCURRENCY="64"        # steady-load latte -p (in-flight request CAP per thread).
                        # Does NOT throttle throughput; use --rate for that.
CONNECTIONS=""          # steady-load latte -c (connections per shard); blank = latte default
DO_SCHEMA="0"           # whether this loader (re)creates schema + loads data
SCYLLA_USER="${SCYLLA_USER:-cassandra}"       # CQL auth user (PasswordAuthenticator)
SCYLLA_PASSWORD="${SCYLLA_PASSWORD:-cassandra}" # CQL auth password

# latte -r/--rate is the precise throughput throttle (cycles/s), set from --rate
# below. The orchestrator derives the per-loader value from the global STEADY_RATE
# (STEADY_RATE / STEADY_LOADERS) and passes it as --rate. Empty = unthrottled
# (latte runs as fast as possible). NOTE: -p/--concurrency alone does NOT limit
# throughput for cheap cache-hit reads.
RATE_ARG=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --role)           ROLE="$2"; shift 2 ;;
        --duration)       DURATION="$2"; shift 2 ;;
        --flood-delay)    FLOOD_DELAY="$2"; shift 2 ;;
        --flood-duration) FLOOD_DURATION="$2"; shift 2 ;;
        --storm-rate)     STORM_RATE="$2"; shift 2 ;;
        --storm-hold)     STORM_HOLD="$2"; shift 2 ;;
        --threads)        THREADS="$2"; shift 2 ;;
        --concurrency)    CONCURRENCY="$2"; shift 2 ;;
        --rate)           [ "$2" -gt 0 ] 2>/dev/null && RATE_ARG="-r $2"; shift 2 ;;
        --connections)    CONNECTIONS="$2"; shift 2 ;;
        --user)           SCYLLA_USER="$2"; shift 2 ;;
        --password)       SCYLLA_PASSWORD="$2"; shift 2 ;;
        --schema)         DO_SCHEMA="1"; shift ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

SCYLLA_IPS="$@"
if [ -z "$SCYLLA_IPS" ]; then
    echo "ERROR: no Scylla IPs provided." >&2
    exit 1
fi

WORKLOAD_PATH="$HOME/workloads/workload.rn"
[ -f "$WORKLOAD_PATH" ] || WORKLOAD_PATH="./workload.rn"
# Dedicated high-rate connection-storm generator (prebuilt Rust binary; shipped
# to the loader by the orchestrator, no build/toolchain needed on the node).
STORM_PATH="$HOME/workloads/connect_storm"
[ -f "$STORM_PATH" ] || STORM_PATH="./connect_storm"

HOST="$(hostname)"
banner() { echo "[$(date '+%H:%M:%S')] [$HOST] $*"; }

# All latte output (CONFIG banner + the final statistics report) is verbose and,
# when streamed back over SSH and multiplied across loaders, floods the console.
# run_latte() sends latte's stdout+stderr to a per-loader log file instead, so the
# console only shows this script's own phase banners. The full latte report stays
# on the loader at $LATTE_LOG for later inspection. On failure we surface a short
# error plus the tail of the log so problems are not silently swallowed.
LATTE_LOG="$HOME/latte-${ROLE}.log"
run_latte() {
    if "$@" >>"$LATTE_LOG" 2>&1; then
        return 0
    fi
    local rc=$?
    banner "[error] latte exited $rc — last lines of $LATTE_LOG:"
    tail -n 15 "$LATTE_LOG" 2>/dev/null | sed 's/^/    /'
    return $rc
}
: >"$LATTE_LOG" 2>/dev/null || true   # truncate any log from a previous run

CONN_ARG=""
[ -n "$CONNECTIONS" ] && CONN_ARG="-c $CONNECTIONS"

# Silence latte's noisy per-line output during the run:
#   -q/--quiet         removes the animated progress bar.
#   -s/--sampling BIG  collapses the periodic statistics log (default 1s, which
#                      prints a numbers row every second and floods the console)
#                      into a single end-of-run sample. 100000s (~27h) is longer
#                      than any run, so no intermediate rows are emitted.
# The final summary report is still printed in full.
QUIET_ARG="-q -s 100000s"

# The cluster runs PasswordAuthenticator, so EVERY latte invocation (schema,
# load, and the steady run) must authenticate or it fails to connect and no
# workload traffic is generated. latte reads --user/--password (long forms; -p
# is already --concurrency).
AUTH_ARG="--user $SCYLLA_USER --password $SCYLLA_PASSWORD"

# Optional: one designated loader prepares schema + pre-populates data.
# This is a PREREQUISITE for every other loader: without the schema and the
# pre-populated `latte.bench` table, the steady 50/50 workload has nothing to
# read/write and silently generates zero benchmark traffic. So if either the
# schema or the data load fails, abort here (non-zero) instead of proceeding —
# otherwise the run degrades into a "storm-only" benchmark that still LOOKS busy
# (the connection storm pins the reactor) while the real load never ran.
if [ "$DO_SCHEMA" = "1" ]; then
    banner "[schema] Initializing schema..."
    if ! run_latte latte schema $AUTH_ARG "$WORKLOAD_PATH" $SCYLLA_IPS; then
        banner "[schema] FATAL: schema creation failed — aborting (see $LATTE_LOG)."
        exit 1
    fi
    banner "[load] Pre-populating 1,000,000 rows..."
    if ! run_latte latte run $QUIET_ARG $AUTH_ARG -f load -d 1000000 --threads 8 --concurrency 64 "$WORKLOAD_PATH" $SCYLLA_IPS; then
        banner "[load] FATAL: data pre-population failed — aborting (see $LATTE_LOG)."
        exit 1
    fi
    banner "[load] Data load complete."
fi

# --- Launch the connection storm in the background (flood / both roles) -------
FLOOD_PID=""
if [ "$ROLE" = "flood" ] || [ "$ROLE" = "both" ]; then
    (
        banner "[storm] Connection storm ARMED — waiting ${FLOOD_DELAY} for baseline..."
        sleep "${FLOOD_DELAY%s}" 2>/dev/null || sleep 120
        banner "[storm] >>> CONNECTION STORM TRIGGERED for ${FLOOD_DURATION} (rate=${STORM_RATE}/s hold=${STORM_HOLD}) <<<"
        "$STORM_PATH" \
            --duration "$FLOOD_DURATION" \
            --rate "$STORM_RATE" \
            --hold "$STORM_HOLD" \
            --user "$SCYLLA_USER" --password "$SCYLLA_PASSWORD" \
            $SCYLLA_IPS
        banner "[storm] <<< CONNECTION STORM ENDED >>>"
    ) &
    FLOOD_PID=$!
fi

# --- Steady-state load (load / both roles) ------------------------------------
# Track the steady-load outcome so we can exit non-zero if latte failed. A failed
# steady run means this loader produced NO benchmark traffic; the orchestrator
# must see that as a failure rather than a clean run.
LOAD_RC=0
if [ "$ROLE" = "load" ] || [ "$ROLE" = "both" ]; then
    banner "[load] >>> STEADY-STATE 50/50 mixed load STARTED (persistent pool, 0 new conns) <<<"
    run_latte latte run $QUIET_ARG $AUTH_ARG -f read:0.5 -f write:0.5 \
        -d "$DURATION" \
        -t "$THREADS" \
        -p "$CONCURRENCY" \
        $RATE_ARG \
        $CONN_ARG \
        "$WORKLOAD_PATH" $SCYLLA_IPS || LOAD_RC=$?
    if [ "$LOAD_RC" -ne 0 ]; then
        banner "[load] ERROR: steady-state load exited $LOAD_RC — no traffic generated (see $LATTE_LOG)."
    else
        banner "[load] <<< STEADY-STATE load FINISHED >>>"
    fi
elif [ -n "$FLOOD_PID" ]; then
    # flood-only role: just wait for the flood to complete.
    banner "[storm] flood-only role; waiting for flood to finish..."
fi

# --- Reap the flood -----------------------------------------------------------
if [ -n "$FLOOD_PID" ]; then
    wait "$FLOOD_PID" 2>/dev/null || true
    banner "[storm] flood process reaped."
fi

banner "Run complete (role=$ROLE)."
# Propagate a failed steady-state load as this loader's exit status so the
# orchestrator flags the run instead of reporting a clean success.
exit "$LOAD_RC"
