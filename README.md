# ScyllaDB Multi-AZ Latte Performance & Connection Storm Benchmark

This benchmarking project deploys a high-performance, production-realistic, multi-AZ **ScyllaDB 3-Node Cluster**, **3 Distributed Latte Loader nodes**, and an **Official Scylla Monitoring node** on AWS EC2 using Terraform.

The ScyllaDB cluster runs with **Precalculated Storage I/O Properties** written at boot time to bypass the slow 15-minute `iotune` test, while still fully engaging Scylla's native thread-per-core I/O scheduling scheduler.

---

## 🏗️ Architecture

1. **VPC (`10.0.0.0/16`)**: Distributed across 3 Availability Zones (AZs) in the target region (e.g. `us-east-1a`, `us-east-1b`, `us-east-1c`).
2. **3 Scylla DB Nodes (`i4i.large`)**: Each node is a 2‑core **x86 (Intel Ice Lake)** instance placed in a different AZ with local NVMe SSD storage formatted as XFS and configured as RAID-0. The cluster enforces **username/password authentication** (`PasswordAuthenticator` + `CassandraAuthorizer`); the default superuser is `cassandra` / `cassandra`.
3. **3 Loader Nodes (`c5.xlarge`)**: Distributed in round-robin fashion across the 3 AZs. Preinstalled with the asynchronous Rust-based **Latte** benchmarking tool.
4. **1 Monitoring Node (`t3.small`)**: Preconfigured with **Scylla Monitoring Stack** (Docker-based Prometheus + Grafana), automatically capturing cluster metrics.

---

## 🚀 Quick Start

### 1. Prerequisites
Ensure you have the following installed locally and configured:
* [Terraform](https://developer.hashicorp.com/terraform/downloads) (>= 1.0)
* [AWS CLI](https://aws.amazon.com/cli/) with configured credentials and region (e.g., `aws configure`)

### 2. Deploy Infrastructure
Initialize and apply the Terraform configuration:

```bash
cd terraform
terraform init
terraform apply
```

*(Optional)* You can restrict SSH and Grafana port access to your local IP address for security:
```bash
terraform apply -var="trusted_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

Terraform will automatically generate a private SSH key file named `tf-scylla-benchmark-key.pem` in the `terraform` directory and print all connection instructions to your terminal.

> ⏳ **Note:** Please wait **2–3 minutes** after `terraform apply` finishes. The instances will be running cloud-init scripts to assemble RAID drives, install packages, and spin up docker containers.

---

## 📊 Run Benchmarks

The benchmark execution is completely automated. Instead of copying IP addresses, you can trigger the entire benchmark pipeline directly from your **local machine**.

### Option A: Local Automation (Recommended)
We provide a local orchestrator script `run_benchmark.sh` in the root of the project. It automatically queries the active Terraform state for Scylla private IPs and Loader public IPs, establishes an SSH tunnel to Loader-0, and launches the entire benchmark suite.

To run the automated benchmark with its **default timing (5-minute steady-state:
a 2-minute warm-up baseline, then a 3-minute connection storm overlapping the
remaining load)**:
```bash
./run_benchmark.sh
```

To customize the steady-state duration (for example, to run for **20 minutes** instead):
```bash
./run_benchmark.sh --duration 20m
```

Throughput is throttled with Latte's `--rate` for a stable, repeatable load.
`--steady-rate` sets the **total** steady ops/s across all steady loaders
(default `14000` ≈ 7k reads + 7k writes), which the orchestrator splits evenly
per steady loader. `--concurrency` only **caps** in-flight requests; it does *not*
limit throughput on cheap cache-hit reads, so use `--steady-rate` to control load:
```bash
./run_benchmark.sh --steady-rate 24000        # ~12k reads + ~12k writes total
```

To keep the console readable, each loader sends its `latte` output (the CONFIG
banner and the full statistics report) to a per-loader log file on that loader
(`~/latte-<role>.log`) rather than streaming it back. Your console therefore shows
only the orchestrator's phase banners and storm progress. If a `latte` run fails,
the loader prints a short error plus the tail of that log so failures aren't
silent. To read the full results, `ssh` to a loader and inspect `~/latte-*.log`.
Press **Ctrl-C** at any time to abort cleanly: the orchestrator tears down the
local SSH sessions **and** signals `latte`/`connect_storm` on every loader to stop
(exit code 130).

The script will automatically:
1. Initialize the Scylla database schema (`latte schema`).
2. Pre-populate the database with 1,000,000 rows (`latte load`).
3. Split the loader fleet into two separate groups: **traffic loaders** run only
   the steady-state 50/50 workload, while **storm loaders** run only the
   dedicated high-rate connection storm generator (the prebuilt `connect_storm`
   Rust binary).
4. Execute the steady-state 50/50 mixed read/write workload on the traffic loaders.
5. After `--flood-delay`, trigger the connection storm on the storm loaders for
   `--flood-duration`, then clean up on completion.

---

### Option B: Manual VM-Level Execution (For Granular Control)

If you prefer to connect to the loader VMs and execute tasks step-by-step:

1. **SSH into Loader-0:**
   ```bash
   ssh -i terraform/tf-scylla-benchmark-key.pem ubuntu@<LOADER_PUBLIC_IP>
   ```

2. **Initialize Database Schema:**
   > The cluster requires auth. Pass `--user`/`--password` **before** the
   > workload path (Latte only honours them in that position).
   ```bash
   latte schema --user cassandra --password cassandra workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

3. **Pre-populate Database (Creates 1,000,000 rows):**
   ```bash
   latte run --user cassandra --password cassandra -f load -d 1000000 --threads 8 --concurrency 64 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

4. **Simulate a Connection Storm (Run in a separate terminal / background):**
   ```bash
   ./workloads/connect_storm --duration 120s --rate 1000 --hold 2s --user cassandra --password cassandra <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```
   > `connect_storm` is a prebuilt Rust binary (async `scylla` driver). `--rate`
   > is new CQL sessions/s **per loader**; with the default 10 storm loaders this
   > targets ~10,000 sessions/s aggregate. Rebuild it from `workloads/connect_storm_rs`
   > with `cargo build --release` if you change the source.

5. **Run Steady-State 50/50 Mixed Workload (reads: 50%, writes: 50%):**
   > `-q` hides the progress bar and `-s 100000s` (a sampling period longer than
   > the run) suppresses the per-second statistics rows, leaving only the final
   > report. `-r` throttles throughput to a steady ops/s (here 7,000 ≈ 3.5k reads
   > + 3.5k writes for this single loader).
   ```bash
   latte run -q -s 100000s --user cassandra --password cassandra -f read:0.5 -f write:0.5 -d 5m --threads 8 --concurrency 64 -r 7000 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

---

## 📈 Monitoring Stack

The official Scylla Monitoring Stack is fully functional on the Monitoring node. 

1. Find the Grafana URL from your terraform output:
   `http://<monitoring-public-ip>:3000`
2. Open the URL in your browser (no password required).
3. Open the **ScyllaDB Overview** or **ScyllaDB Detailed** dashboard.
4. Observe real-time statistics including:
   * Read and Write latency histograms (coordinated in real time across nodes).
   * **CPU utilization per Shard** (Scylla's share-nothing asynchronous executor).
   * **CQL Connection count** (watch this spike under connection storm tests). The
     storm shuffles its contact points per session and uses a round-robin policy,
     so new connections spread **evenly across all 3 nodes** rather than piling
     onto the seed.
   * I/O queue delays, disk writes/reads, and compaction rates.

---

## 📸 Download a Monitoring Snapshot

You can capture the monitoring node's **Prometheus time-series database** (all raw
metrics from the run) and analyze it offline — even after the cluster is torn
down. Snapshots are downloaded to `./snapshots/<timestamp>/prometheus_data/`.

Capture a snapshot at any time (infra must be up):
```bash
./fetch_snapshot.sh
```

Or capture automatically right after a benchmark run:
```bash
./run_benchmark.sh --snapshot
```

Under the hood `fetch_snapshot.sh` SSHes to the monitoring node, gracefully stops
the Prometheus container (flushing the head block + WAL to disk), `tar`s
`/var/lib/prometheus`, restarts Prometheus, then downloads and extracts the
archive locally.

### Load a snapshot locally

The snapshot is loaded with the official Scylla Monitoring stack in **archive
mode** (infinite retention, reads the ScyllaDB version from the bundled
`scylla.txt`):
```bash
cd /code/scylladb/scylla-monitoring
./start-all.sh --archive /path/to/snapshots/<timestamp>/prometheus_data
```
Then open Grafana at `http://localhost:3000`. Stop it later with `./kill-all.sh`.

---

## 🔁 Full Automated Pipeline

`run_full_benchmark.sh` runs the **entire lifecycle** with one command:

1. `terraform apply` — provision the cluster, loaders, and monitoring node.
2. Wait for the loaders and monitoring node to finish cloud-init.
3. Run the benchmark (traffic loaders + connection-storm loaders).
4. Fetch the Prometheus snapshot from the monitoring node.
5. `terraform destroy` — **always** torn down, even if the benchmark or snapshot
   step failed (teardown runs from a shell trap so AWS resources are never left
   running).
6. Load the snapshot into a **local** Scylla Monitoring stack so you can browse
   the exact dashboards offline after the infra is gone.

```bash
# Defaults: local monitoring repo at /code/scylladb/scylla-monitoring
./run_full_benchmark.sh

# Forward benchmark options after a literal `--`:
./run_full_benchmark.sh -- --duration 3m --steady-loaders 2 --storm-rate 30

# Restrict access to your IP, use a different monitoring checkout, skip local load:
./run_full_benchmark.sh \
    --tf-var "trusted_cidr=$(curl -s https://checkip.amazonaws.com)/32" \
    --monitoring-dir /path/to/scylla-monitoring \
    --no-load \
    -- --duration 15m
```

> ⚠️ Because teardown is unconditional, don't rely on the cluster still being up
> after this script finishes. Use `./run_benchmark.sh` directly if you want the
> infrastructure to persist for manual inspection.

---

## 🧼 Tear Down

Once your benchmarking is complete, clean up all AWS resources to avoid any ongoing charges:

```bash
cd terraform
terraform destroy
```
This will cleanly terminate all VM instances, tear down VPC subnets, and remove the locally generated SSH private key.
