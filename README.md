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

## 🚀 Quick Start

### 1. Provision Infrastructure
Initialize and apply the Terraform configuration:
```bash
cd terraform
terraform init
terraform apply -var="trusted_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```
*Wait 2–3 minutes after `apply` completes for instances to finish cloud-init initialization (assembling RAIDs, installing packages, etc.).*

### 2. Run the Benchmark
The entire benchmark is managed via the local orchestrator from your root directory:
```bash
./run_benchmark.sh
```

**What it does automatically:**
1. Initializes the keyspace and tables on ScyllaDB (`latte schema`).
2. Splits the loaders into a balanced zone-aligned topology:
   * **3 Steady Loaders** (exactly 1 per AZ) run mixed 50/50 read/write traffic at a total rate of `28000` ops/s (approx. 14k reads + 14k writes), routing queries directly to their local-zone coordinator.
   * **15 Storm Loaders** (exactly 5 per AZ) trigger Scylla's native `perf-cql-raw --workload connect` targeting only their local-zone node.
3. Automatically harvests and bundles all loader logs (`latte-load.log`, `storm-*.log`) and Scylla server systemd logs (`journalctl -u scylla-server`) into `./logs/` locally before teardown.

---

## 📊 Command-Line Options

### Orchestrator (`./run_benchmark.sh`)
Customize the run by passing flags:
```bash
./run_benchmark.sh \
    --duration 10m \
    --steady-rate 36000 \
    --storm-connections-per-shard 128 \
    --storm-concurrency-per-shard 1
```

* **`--duration`**: Total benchmark time (default `5m`).
* **`--steady-rate`**: Target cluster-wide mixed load ops/s (default `28000`).
* **`--steady-loaders`**: Number of steady traffic VMs (default `3`).
* **`--storm-connections-per-shard`**: Connection count per shard on storm processes (default `128`).
* **`--storm-concurrency-per-shard`**: Connection concurrency factor per shard on storm processes (default `1`).
* **`--storm-only`**: Skip steady traffic and schema setup; put all 18 loaders in connection-storm mode.

---

## 🔁 Full Automated Pipeline

`./run_full_benchmark.sh` handles the **entire lifecycle** in one command:
1. `terraform apply` to provision all nodes.
2. Waits for cloud-init provisioning.
3. Runs the benchmark (including automatic local log harvesting).
4. Automatically downloads a Prometheus metrics snapshot.
5. `terraform destroy` (unconditional EXIT trap, guaranteeing no leftover AWS resources).
6. Loads the metrics snapshot into your **local** Scylla Monitoring Stack (`/code/scylladb/scylla-monitoring`).
7. Auto-focuses the Grafana dashboard to the exact benchmark run timeline.

```bash
./run_full_benchmark.sh
```

At the end of the run, the precise start, storm-trigger, and end times are printed to your console:
```
Start: 2026-07-03 15:10:00 UTC (17:10:00 Local)
Storm Start: 2026-07-03 15:12:00 UTC (17:12:00 Local)
End: 2026-07-03 15:15:00 UTC (17:15:00 Local)
```

Open Grafana locally at: **http://localhost:3000/d/scylla-benchmark/scylladb-benchmark**

---

## 🧼 Manual Tear Down
If running the standalone orchestrator, destroy the AWS resources once complete:
```bash
cd terraform
terraform destroy
```