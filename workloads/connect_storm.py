#!/usr/bin/env python3
"""Dedicated CQL connection-storm generator for ScyllaDB.

This runs ON A SINGLE LOADER and produces a controlled stream of SHORT-LIVED
CQL sessions to drive up

    rate(scylla_transport_cql_connections[...])   (new connections / second)

Unlike the old latte-based storm (which abused `latte run` process churn),
this tool uses the ScyllaDB Python driver (`scylla-driver`) so every session
performs a real TCP + CQL handshake and therefore registers as a genuine CQL
connection on the server. Each session is:

    1. opened  (connect() -> new CQL connections established)
    2. HELD for --hold seconds (default 2s, per request)
    3. closed  (shutdown() -> connections torn down)

Opening sessions at a steady RATE (new sessions/second) and letting each live
for a fixed HOLD gives a smooth, *controllable* new-connection rate rather than
the spiky back-to-back waves of the previous approach. Lowering --rate makes
the storm less steep; raising it makes it steeper.

The orchestrator launches this on every storm loader in parallel; the aggregate
flood rate is (per-loader rate x number of storm loaders).

Usage:
    connect_storm.py --duration 120s --rate 40 --hold 2s \
        <scylla-ip-1> [scylla-ip-2 ...]

Env-var overrides (fallbacks for the CLI flags):
    STORM_RATE            new sessions opened per second  (default 40)
    STORM_HOLD            seconds each session is held     (default 2)
    STORM_CONN_PER_HOST   CQL connections per host/session (default 1)
"""

import argparse
import os
import sys
import threading
import time

try:
    from cassandra.cluster import Cluster
    from cassandra.policies import RoundRobinPolicy, TokenAwarePolicy
except ImportError:
    sys.stderr.write(
        "ERROR: the ScyllaDB Python driver is not installed.\n"
        "       Install it with:  pip3 install scylla-driver\n"
    )
    sys.exit(2)

# HostDistance lives in cassandra.pool but its exact location/availability has
# varied across driver versions; import it best-effort for optional pool sizing.
try:
    from cassandra.pool import HostDistance
except Exception:  # pragma: no cover - optional
    HostDistance = None


def parse_duration(text, default_seconds):
    """Parse a duration like '120s', '2m', '500ms', or a bare number of seconds."""
    if text is None:
        return float(default_seconds)
    text = str(text).strip().lower()
    try:
        if text.endswith("ms"):
            return float(text[:-2]) / 1000.0
        if text.endswith("s"):
            return float(text[:-1])
        if text.endswith("m"):
            return float(text[:-1]) * 60.0
        if text.endswith("h"):
            return float(text[:-1]) * 3600.0
        return float(text)
    except ValueError:
        return float(default_seconds)


def open_hold_close(contact_points, port, conn_per_host, hold_secs, stats, stats_lock):
    """Open one CQL session, hold it, then close it. Runs in its own thread."""
    cluster = None
    try:
        # A fresh Cluster per session guarantees a fresh set of CQL connections
        # (new TCP + CQL STARTUP handshakes) rather than reusing a pool.
        cluster = Cluster(
            contact_points=contact_points,
            port=port,
            load_balancing_policy=TokenAwarePolicy(RoundRobinPolicy()),
            protocol_version=4,
            connect_timeout=10,
        )
        # Best-effort: pin connections-per-host so --rate maps cleanly onto
        # new-connections/second. The setter API is not present in every driver
        # build, so guard it and fall back to the driver defaults if absent.
        _set_min = getattr(cluster, "set_min_connections_per_host", None)
        _set_max = getattr(cluster, "set_max_connections_per_host", None)
        if HostDistance is not None and _set_min and _set_max:
            for dist in (HostDistance.LOCAL, HostDistance.REMOTE):
                _set_min(dist, conn_per_host)
                _set_max(dist, conn_per_host)
        session = cluster.connect()
        # Keep a trivial liveness query so the session is fully established.
        session.execute("SELECT now() FROM system.local")
        with stats_lock:
            stats["opened"] += 1
        time.sleep(hold_secs)
    except Exception:
        with stats_lock:
            stats["failed"] += 1
    finally:
        if cluster is not None:
            try:
                cluster.shutdown()
            except Exception:
                pass
            with stats_lock:
                stats["closed"] += 1


def main():
    ap = argparse.ArgumentParser(description="Dedicated CQL connection-storm generator.")
    ap.add_argument("--duration", default="120s",
                    help="total storm length (e.g. 120s, 2m). Default 120s.")
    ap.add_argument("--rate", type=float,
                    default=float(os.environ.get("STORM_RATE", "40")),
                    help="new sessions opened per second (steepness knob). Default 40.")
    ap.add_argument("--hold", default=os.environ.get("STORM_HOLD", "2s"),
                    help="how long each session is held before closing. Default 2s.")
    ap.add_argument("--conn-per-host", type=int,
                    default=int(os.environ.get("STORM_CONN_PER_HOST", "1")),
                    help="CQL connections per host per session. Default 1.")
    ap.add_argument("--port", type=int, default=9042, help="CQL port. Default 9042.")
    ap.add_argument("nodes", nargs="+", help="ScyllaDB node IP(s).")
    args = ap.parse_args()

    duration_secs = parse_duration(args.duration, 120)
    hold_secs = parse_duration(args.hold, 2)
    rate = max(args.rate, 0.001)
    interval = 1.0 / rate  # seconds between successive session launches

    host = os.uname().nodename

    print("=========================================================================")
    print(f" CONNECTION STORM (scylla-driver) starting on {host}")
    print(f"   target nodes      : {' '.join(args.nodes)}")
    print(f"   duration          : {args.duration}  ({duration_secs:.0f}s)")
    print(f"   launch rate       : {rate:g} new sessions/s  (steepness)")
    print(f"   hold per session  : {args.hold}  ({hold_secs:g}s)")
    print(f"   conns per host    : {args.conn_per_host}")
    print("=========================================================================")
    sys.stdout.flush()

    stats = {"opened": 0, "closed": 0, "failed": 0}
    stats_lock = threading.Lock()
    threads = []

    deadline = time.time() + duration_secs
    next_launch = time.time()

    # Launch new sessions at a steady cadence until the deadline. Each session
    # lives for hold_secs in its own thread, so at steady state roughly
    # (rate * hold_secs) sessions are concurrently open.
    while time.time() < deadline:
        now = time.time()
        if now < next_launch:
            time.sleep(min(next_launch - now, 0.05))
            continue
        t = threading.Thread(
            target=open_hold_close,
            args=(args.nodes, args.port, args.conn_per_host,
                  hold_secs, stats, stats_lock),
            daemon=True,
        )
        t.start()
        threads.append(t)
        next_launch += interval
        # Periodically reap finished threads so the list doesn't grow unbounded.
        if len(threads) >= 1024:
            threads = [x for x in threads if x.is_alive()]

    # Drain: wait for the last in-flight sessions to finish their hold + close.
    print(f"[{host}] storm launch window closed; draining in-flight sessions...")
    sys.stdout.flush()
    for t in threads:
        t.join(timeout=hold_secs + 15)

    with stats_lock:
        opened = stats["opened"]
        closed = stats["closed"]
        failed = stats["failed"]
    print("=========================================================================")
    print(f" CONNECTION STORM finished on {host}: "
          f"opened={opened} closed={closed} failed={failed}")
    print("=========================================================================")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
