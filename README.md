# ScyllaDB Multi-AZ Latte Performance & Connection Storm Benchmark

This project deploys a high-performance **ScyllaDB 3-Node Cluster**, **18 Distributed Latte Loader nodes**, and an **Official Scylla Monitoring node** on AWS EC2 using Terraform.

The benchmark isolates steady mixed-traffic loaders from connection-storm loaders in a highly optimized, zone-aligned topology.

---

## 🏗️ Architecture

1. **VPC (`10.0.0.0/16`)**: Spans 3 Availability Zones (AZs) (e.g., `us-east-1a`, `us-east-1b`, `us-east-1c`).
2. **3 Scylla DB Nodes (`i4i.large`)**: Multi-AZ (1 node per AZ), 2 vCPUs, local NVMe SSD (RAID-0 XFS). Bypasses the 15-minute `iotune` test via precalculated properties. Authenticator: `PasswordAuthenticator` (`cassandra`/`cassandra`).
3. **18 Loader Nodes (`c5.xlarge`)**: Distributed round-robin across the 3 AZs. Preinstalled with Scylla client tools (`perf-cql-raw`) and the Rust-based **Latte** tool.
4. **1 Monitoring Node (`t3.small`)**: Preconfigured Scylla Monitoring Stack (Prometheus + Grafana).

---

## 🚀 Reusable Execution Modes

We provide two execution flows. The **full automated script** handles the entire lifecycle in a single command and is highly recommended. The **granular manual flow** allows for custom iteration while keeping infrastructure active.

### Flow A: Full Automated Pipeline (`run_full_benchmark.sh`) [Recommended]

`./run_full_benchmark.sh` handles the **entire lifecycle** of provisioning, testing, log collection, snapshot retrieval, teardown, and local visualization in **one command**:

```bash
# Run with defaults (targets 2026.2.0, prompts for version if not supplied)
./run_full_benchmark.sh
```

**What it does automatically:**
1. Spawns AWS infrastructure (`terraform apply`).
2. Waits for all loaders and monitoring to finish cloud-init initialization.
3. Automatically sets up the schema and runs the benchmark phases.
4. Downloads all metrics as a Prometheus snapshot.
5. Destroys the AWS infrastructure (`terraform destroy` is wrapped in a shell trap so it **always** tears down, even on errors/Ctrl-C).
6. Loads the metrics snapshot locally and auto-zooms your local Scylla Monitoring Stack (`/code/scylladb/scylla-monitoring`) to the exact run window.

At the end of the run, the precise start, storm-trigger, and end times are printed to your console:
```
Start: 2026-07-03 15:10:00 UTC (17:10:00 Local)
Storm Start: 2026-07-03 15:12:00 UTC (17:12:00 Local)
End: 2026-07-03 15:15:00 UTC (17:15:00 Local)
```

Open Grafana locally at: **http://localhost:3000/d/scylla-benchmark/scylladb-benchmark**

---

### Flow B: Granular Manual Pipeline

For manual, iterative testing where you want the AWS infrastructure to remain alive between runs:

#### 1. Provision Infrastructure
```bash
cd terraform
terraform init
terraform apply -var="trusted_cidr=$(curl -s https://checkip.amazonaws.com)/32"
cd ..
```
*Wait 2–3 minutes after `apply` completes for instances to finish cloud-init setup.*

#### 2. Run the Benchmark Standalone
```bash
./run_benchmark.sh
```

**What the orchestrator does automatically:**
1. Initializes the keyspace and tables on ScyllaDB (`latte schema`).
2. Splits loaders into a balanced zone-aligned topology:
   * **3 Steady Loaders** (exactly 1 per AZ) run mixed 50/50 read/write traffic at a total rate of `28000` ops/s (approx. 14k reads + 14k writes), routing queries directly to their local-zone coordinator.
   * **15 Storm Loaders** (exactly 5 per AZ) trigger Scylla's native `perf-cql-raw --workload connect` targeting only their local-zone node (generating up to 500+ active ports/sockets at once per loader).
3. Automatically harvests and bundles all loader logs (`latte-load.log`, `storm-*.log`) and Scylla server systemd logs (`journalctl -u scylla-server`) into `./logs/` locally, clearing previous logs first.

#### 3. Tear Down Manually
When complete, manually destroy all AWS resources to avoid any ongoing charges:
```bash
cd terraform
terraform destroy
```

---

## 📊 Command-Line Customization

Both scripts accept optional flags to customize the benchmark run parameters. Pass them directly to `run_benchmark.sh`, or append them after a literal `--` in `run_full_benchmark.sh`:

```bash
# Example customization for full automated run:
./run_full_benchmark.sh --scylla-version 2025.1.9 -- --duration 10m --steady-rate 36000
```

* **`--scylla-version`**: Specific version to install on DB nodes (default: prompts interactively for `2026.2.0`, `2025.1.9`, or custom. *Note: Storm loaders always install the stable 2026.2 branch to ensure `perf-cql-raw` availability*).
* **`--duration`**: Total benchmark time (default `5m`).
* **`--steady-rate`**: Target cluster-wide mixed load ops/s (default `28000`).
* **`--steady-loaders`**: Number of steady traffic VMs (default `3`).
* **`--storm-connections-per-shard`**: Connection count per shard on storm processes (default `128`).
* **`--storm-concurrency-per-shard`**: Connection concurrency factor per shard on storm processes (default `1`).
* **`--storm-only`**: Skip steady traffic and schema setup; put all 18 loaders in connection-storm mode.
