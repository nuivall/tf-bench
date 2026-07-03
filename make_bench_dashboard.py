#!/usr/bin/env python3
"""Build (and optionally upload) a ScyllaDB benchmark Grafana dashboard.

Creates a dashboard focused on the connection-storm / steady-load benchmark:
latency, throughput, CQL/read errors, and connection shedding/blocking. Panels
query the Prometheus datasource and use Grafana's $__rate_interval so they work
at any zoom level (live cluster or an --archive snapshot load).

Usage:
    # Build + upload to the locally running Grafana (default):
    ./make_bench_dashboard.py

    # Just write the dashboard JSON to a file, don't upload:
    ./make_bench_dashboard.py --out bench_dashboard.json --no-upload

    # Target a different Grafana / datasource:
    ./make_bench_dashboard.py --grafana-url http://localhost:3000 \
                              --datasource-uid prometheus

The Scylla Monitoring stack runs Grafana with anonymous admin access (no auth),
so no credentials are needed by default. Pass --user/--password if yours differs.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

DASH_TITLE = "ScyllaDB Benchmark"
DASH_UID = "scylla-benchmark"

# Panel definitions in display order. Each is (title, promql, unit, description).
# Units: "percentunit" (0-1), "s" (seconds), "ops" (ops/s), "short" (plain count/s).
PANELS = [
    # ---- Utilization ---------------------------------------------------------
    (
        "Reactor Utilization by Instance",
        'avg by (instance) (scylla_reactor_utilization{})',
        "percent",  # scylla_reactor_utilization is already 0-100
        "Average CPU (reactor) busy fraction per node. The primary saturation "
        "signal.\n\nscylla_reactor_utilization",
    ),
    # ---- Connections ---------------------------------------------------------
    (
        "CQL Connections (current) by Instance",
        'sum(scylla_transport_current_connections{}) by (instance)',
        "short",
        "Currently-open CQL connections per node (gauge).\n\n"
        "scylla_transport_current_connections",
    ),
    (
        "CQL New Connections/s by Instance",
        'sum(rate(scylla_transport_cql_connections{}[$__rate_interval])) by (instance)',
        "short",
        "New CQL connections per second per node — the connection-storm arrival "
        "rate.\n\nscylla_transport_cql_connections (rate of the cumulative "
        "new-connections counter)",
    ),
    (
        "CQL Connections Shed",
        'sum(rate(scylla_transport_connections_shed{}[$__rate_interval])) by (job)',
        "short",
        "New CQL connections shed/s (rejected by the server under connection "
        "pressure).\n\nscylla_transport_connections_shed",
    ),
    (
        "CQL Connections Blocked",
        'sum(rate(scylla_transport_connections_blocked{}[$__rate_interval])) by (job)',
        "short",
        "New CQL connections blocked/s (throttled at admission).\n\n"
        "scylla_transport_connections_blocked",
    ),
    # ---- Latency & throughput ------------------------------------------------
    (
        "Read p99 Latency by Scheduling Group",
        'max(rlatencyp99{}>0) by (scheduling_group_name) / 1000',
        "ms",
        "Coordinator read p99 latency per scheduling group (service level).\n\n"
        "rlatencyp99 / 1000 (us -> ms)",
    ),
    (
        "Write p99 Latency by Scheduling Group",
        'max(wlatencyp99{}>0) by (scheduling_group_name) / 1000',
        "ms",
        "Coordinator write p99 latency per scheduling group (service level).\n\n"
        "wlatencyp99 / 1000 (us -> ms)",
    ),
    (
        "Read Throughput by Scheduling Group",
        'sum(rate(scylla_storage_proxy_coordinator_read_latency_count{}[$__rate_interval])) by (scheduling_group_name)',
        "ops",
        "Coordinator read ops/s per scheduling group.\n\n"
        "scylla_storage_proxy_coordinator_read_latency_count",
    ),
    (
        "Write Throughput by Scheduling Group",
        'sum(rate(scylla_storage_proxy_coordinator_write_latency_count{}[$__rate_interval])) by (scheduling_group_name)',
        "ops",
        "Coordinator write ops/s per scheduling group.\n\n"
        "scylla_storage_proxy_coordinator_write_latency_count",
    ),
    # ---- Errors & failures ---------------------------------------------------
    (
        "CQL Errors by Type",
        'sum(rate(scylla_transport_cql_errors_total{}[$__rate_interval])) by (type,job)',
        "short",
        "CQL protocol errors/s broken down by type (read_failure, read_timeout, "
        "server_error, ...).\n\nscylla_transport_cql_errors_total",
    ),
    (
        "Failed Reads by Class",
        'sum(rate(scylla_database_total_reads_failed{}[$__rate_interval])) by (class)',
        "short",
        "Replica-side failed reads/s per scheduling class. Tracks reader-admission "
        "shedding under load.\n\nscylla_database_total_reads_failed",
    ),
]

# 2-column grid: each panel 12 wide x 8 tall.
PANEL_W = 12
PANEL_H = 8
COLS = 2


def build_panel(panel_id, title, expr, unit, description, ds_uid, x, y):
    ds = {"type": "prometheus", "uid": ds_uid}
    return {
        "id": panel_id,
        "type": "timeseries",
        "title": title,
        "description": description,
        "datasource": ds,
        "gridPos": {"h": PANEL_H, "w": PANEL_W, "x": x, "y": y},
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {
                    "drawStyle": "line",
                    "lineInterpolation": "linear",
                    "fillOpacity": 10,
                    "showPoints": "never",
                    "lineWidth": 1,
                },
            },
            "overrides": [],
        },
        "options": {
            "legend": {"displayMode": "table", "placement": "bottom", "calcs": ["last", "max"]},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": [
            {
                "datasource": ds,
                "expr": expr,
                "legendFormat": "__auto",
                "range": True,
                "refId": "A",
            }
        ],
    }


def build_dashboard(ds_uid, time_from=None, time_to=None):
    panels = []
    for i, (title, expr, unit, desc) in enumerate(PANELS):
        x = (i % COLS) * PANEL_W
        y = (i // COLS) * PANEL_H
        panels.append(build_panel(i + 1, title, expr, unit, desc, ds_uid, x, y))
    return {
        "uid": DASH_UID,
        "title": DASH_TITLE,
        "tags": ["scylla", "benchmark", "connection-storm"],
        "timezone": "browser",
        "schemaVersion": 42,
        "refresh": "",
        "time": {"from": time_from or "now-1h", "to": time_to or "now"},
        "panels": panels,
    }


def upload(dashboard, grafana_url, user, password):
    payload = {
        "dashboard": dashboard,
        "overwrite": True,
        "message": "Automated benchmark dashboard",
    }
    data = json.dumps(payload).encode()
    url = grafana_url.rstrip("/") + "/api/dashboards/db"
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if user:
        import base64

        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"ERROR: Grafana returned {e.code}: {e.read().decode()}\n")
        return None
    except urllib.error.URLError as e:
        sys.stderr.write(f"ERROR: could not reach Grafana at {url}: {e}\n")
        return None
    return body


def post_annotation(grafana_url, user, password, time_ms, time_end_ms, text, tags):
    payload = {
        "dashboardUID": DASH_UID,
        "time": time_ms,
        "timeEnd": time_end_ms,
        "tags": tags,
        "text": text
    }
    data = json.dumps(payload).encode()
    url = grafana_url.rstrip("/") + "/api/annotations"
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if user:
        import base64
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except Exception as e:
        sys.stderr.write(f"WARNING: failed to post annotation '{text}': {e}\n")


def delete_annotations(grafana_url, user, password):
    # Query existing annotations for this dashboard to prevent duplicate markings on re-runs.
    url = grafana_url.rstrip("/") + f"/api/annotations?dashboardUID={DASH_UID}"
    req = urllib.request.Request(url, method="GET")
    token = None
    if user:
        import base64
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            annos = json.loads(resp.read().decode())
        for anno in annos:
            anno_id = anno.get("id")
            if anno_id:
                del_url = grafana_url.rstrip("/") + f"/api/annotations/{anno_id}"
                del_req = urllib.request.Request(del_url, method="DELETE")
                if token:
                    del_req.add_header("Authorization", f"Basic {token}")
                with urllib.request.urlopen(del_req, timeout=10) as del_resp:
                    del_resp.read()
    except Exception as e:
        sys.stderr.write(f"WARNING: failed to clear old annotations: {e}\n")


def create_annotations(grafana_url, user, password, ts_data):
    # First, clear any existing annotations for this dashboard to prevent duplicates.
    delete_annotations(grafana_url, user, password)

    # Annotation 1: Steady Load
    if not ts_data.get("storm_only") and ts_data.get("load_start") and ts_data.get("load_end"):
        post_annotation(
            grafana_url, user, password,
            ts_data["load_start"] * 1000,
            ts_data["load_end"] * 1000,
            "Steady Load Phase (Mixed 50/50 Traffic)",
            ["load", "steady-state"]
        )

    # Annotation 2: Connection Storm
    if ts_data.get("storm_start") and ts_data.get("storm_end"):
        post_annotation(
            grafana_url, user, password,
            ts_data["storm_start"] * 1000,
            ts_data["storm_end"] * 1000,
            "Connection Storm Phase (perf-cql-raw)",
            ["storm", "flood"]
        )


def main():
    ap = argparse.ArgumentParser(description="Build/upload the ScyllaDB benchmark dashboard.")
    ap.add_argument("--grafana-url", default="http://localhost:3000",
                    help="Grafana base URL (default: http://localhost:3000).")
    ap.add_argument("--datasource-uid", default="prometheus",
                    help="Prometheus datasource UID (default: prometheus).")
    ap.add_argument("--out", default=None,
                    help="Also write the dashboard JSON to this file.")
    ap.add_argument("--no-upload", action="store_true",
                    help="Build only; do not upload to Grafana.")
    ap.add_argument("--user", default=None, help="Grafana basic-auth user (default: none/anon).")
    ap.add_argument("--password", default="", help="Grafana basic-auth password.")
    ap.add_argument("--timestamps-file", default=None,
                    help="JSON file containing the benchmark run start/end timestamps to adjust dashboard window.")
    args = ap.parse_args()

    ts_data = None
    time_from = None
    time_to = None
    if args.timestamps_file:
        try:
            with open(args.timestamps_file) as f:
                ts_data = json.load(f)
            if ts_data.get("workload_start") and ts_data.get("workload_end"):
                # Focus default view to exactly the run window (with a 30s margin on each side)
                time_from = str((ts_data["workload_start"] - 30) * 1000)
                time_to = str((ts_data["workload_end"] + 30) * 1000)
        except Exception as e:
            sys.stderr.write(f"WARNING: failed to read timestamps file '{args.timestamps_file}': {e}\n")

    dashboard = build_dashboard(args.datasource_uid, time_from, time_to)

    if args.out:
        with open(args.out, "w") as f:
            json.dump(dashboard, f, indent=2)
        print(f"Wrote dashboard JSON to {args.out}")

    if args.no_upload:
        if not args.out:
            print(json.dumps(dashboard, indent=2))
        return 0

    result = upload(dashboard, args.grafana_url, args.user, args.password)
    if not result:
        return 1
    status = result.get("status", "?")
    uid = result.get("uid", DASH_UID)
    url_path = result.get("url", f"/d/{uid}")
    print(f"Dashboard uploaded (status={status}).")
    print(f"Open it at: {args.grafana_url.rstrip('/')}{url_path}")

    if ts_data:
        print("Adding phase region markings to Grafana dashboard...")
        create_annotations(args.grafana_url, args.user, args.password, ts_data)

    return 0


if __name__ == "__main__":
    sys.exit(main())
