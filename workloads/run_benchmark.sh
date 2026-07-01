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
#                    (connect_storm.py) for FLOOD_DURATION. No steady traffic.
#                    This is the "storm" role and does NOT run steady load.
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
#                    [--duration 5m] [--flood-delay 120s] [--flood-duration 120s] \
#                    [--storm-rate 40] [--storm-hold 2s] \
#                    [--threads N] [--concurrency N] [--connections N] \
#                    <scylla-ip-1> [scylla-ip-2 ...]
set -u

ROLE="both"
DURATION="5m"           # steady-state length
FLOOD_DELAY="120s"      # wait before the storm, to capture a clean baseline
FLOOD_DURATION="120s"   # how long the storm lasts (2x the old 60s)
STORM_RATE="40"         # storm: new CQL sessions opened per second (steepness)
STORM_HOLD="2s"         # storm: how long each session is held before closing
THREADS="8"             # steady-load latte -t
CONCURRENCY="64"        # steady-load latte -p (async requests per thread)
CONNECTIONS=""          # steady-load latte -c (connections per shard); blank = latte default
DO_SCHEMA="0"           # whether this loader (re)creates schema + loads data

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
        --connections)    CONNECTIONS="$2"; shift 2 ;;
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
STORM_PATH="$HOME/workloads/connect_storm.py"
[ -f "$STORM_PATH" ] || STORM_PATH="./connect_storm.py"

HOST="$(hostname)"
banner() { echo "[$(date '+%H:%M:%S')] [$HOST] $*"; }

CONN_ARG=""
[ -n "$CONNECTIONS" ] && CONN_ARG="-c $CONNECTIONS"

echo "========================================================================="
echo " PER-LOADER RUN  host=$HOST  role=$ROLE"
echo "   scylla targets : $SCYLLA_IPS"
echo "   steady load    : -f read:0.5 -f write:0.5 -d $DURATION -t $THREADS -p $CONCURRENCY $CONN_ARG"
echo "   storm          : delay=$FLOOD_DELAY duration=$FLOOD_DURATION rate=${STORM_RATE}/s hold=$STORM_HOLD (role-dependent)"
echo "========================================================================="

# Optional: one designated loader prepares schema + pre-populates data.
if [ "$DO_SCHEMA" = "1" ]; then
    banner "[schema] Initializing schema..."
    latte schema "$WORKLOAD_PATH" $SCYLLA_IPS
    banner "[load] Pre-populating 1,000,000 rows..."
    latte run -f load -d 1000000 --threads 8 --concurrency 64 "$WORKLOAD_PATH" $SCYLLA_IPS
    banner "[load] Data load complete."
fi

# --- Launch the connection storm in the background (flood / both roles) -------
FLOOD_PID=""
if [ "$ROLE" = "flood" ] || [ "$ROLE" = "both" ]; then
    (
        banner "[storm] Connection storm ARMED — waiting ${FLOOD_DELAY} for baseline..."
        sleep "${FLOOD_DELAY%s}" 2>/dev/null || sleep 120
        banner "[storm] >>> CONNECTION STORM TRIGGERED for ${FLOOD_DURATION} (rate=${STORM_RATE}/s hold=${STORM_HOLD}) <<<"
        python3 "$STORM_PATH" \
            --duration "$FLOOD_DURATION" \
            --rate "$STORM_RATE" \
            --hold "$STORM_HOLD" \
            $SCYLLA_IPS
        banner "[storm] <<< CONNECTION STORM ENDED >>>"
    ) &
    FLOOD_PID=$!
fi

# --- Steady-state load (load / both roles) ------------------------------------
if [ "$ROLE" = "load" ] || [ "$ROLE" = "both" ]; then
    banner "[load] >>> STEADY-STATE 50/50 mixed load STARTED (persistent pool, 0 new conns) <<<"
    latte run -f read:0.5 -f write:0.5 \
        -d "$DURATION" \
        -t "$THREADS" \
        -p "$CONCURRENCY" \
        $CONN_ARG \
        "$WORKLOAD_PATH" $SCYLLA_IPS
    banner "[load] <<< STEADY-STATE load FINISHED >>>"
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
