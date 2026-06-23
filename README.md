# ScyllaDB Multi-AZ Latte Performance & Connection Storm Benchmark

This benchmarking project deploys a high-performance, production-realistic, multi-AZ **ScyllaDB 3-Node Cluster**, **3 Distributed Latte Loader nodes**, and an **Official Scylla Monitoring node** on AWS EC2 using Terraform.

The ScyllaDB cluster runs with **Precalculated Storage I/O Properties** written at boot time to bypass the slow 15-minute `iotune` test, while still fully engaging Scylla's native thread-per-core I/O scheduling scheduler.

---

## 🏗️ Architecture

1. **VPC (`10.0.0.0/16`)**: Distributed across 3 Availability Zones (AZs) in the target region (e.g. `us-east-1a`, `us-east-1b`, `us-east-1c`).
2. **3 Scylla DB Nodes (`i3en.xlarge`)**: Each node is placed in a different AZ with local NVMe SSD storage formatted as XFS and configured as RAID-0.
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

### Step 1: SSH into Loader-0
Find your loader's public IP from the terraform output and connect:
```bash
ssh -i terraform/tf-scylla-benchmark-key.pem ubuntu@<LOADER_PUBLIC_IP>
```

### Option A: The Automated Way (Recommended)
We have provided an automated wrapper script `run_benchmark.sh` that takes care of the entire execution pipeline in a single command:
1. Initializes the keyspace and tables (replication factor of 3).
2. Pre-populates the database with 1,000,000 rows of payload data.
3. Automatically launches the connection storm generator in the background.
4. Executes the steady-state 50/50 mixed read/write workload.
5. Gracefully terminates and cleans up the connection storm upon completion.

To run the automated script with its **default duration of 5 minutes (`5m`)**:
```bash
./workloads/run_benchmark.sh <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```

You can customize the steady-state duration (for example, to run for **10 minutes** instead):
```bash
./workloads/run_benchmark.sh --duration 10m <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```

---

### Option B: The Manual Way (For Granular Control)

If you prefer to run each stage manually:

1. **Initialize Database Schema:**
   ```bash
   latte schema workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

2. **Pre-populate Database (Creates 1,000,000 rows):**
   ```bash
   latte run -f load -d 1000000 --threads 8 --concurrency 64 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

3. **Simulate a Connection Storm (Run in a separate terminal / background):**
   ```bash
   ./workloads/connect_storm.sh <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
   ```

4. **Run Steady-State 50/50 Mixed Workload (reads: 50%, writes: 50%):**
   ```bash
   latte run -f read:0.5 -f write:0.5 -d 10m --threads 8 --concurrency 64 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
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
   * **CQL Connection count** (watch this spike under connection storm tests).
   * I/O queue delays, disk writes/reads, and compaction rates.

---

## 🧼 Tear Down

Once your benchmarking is complete, clean up all AWS resources to avoid any ongoing charges:

```bash
cd terraform
terraform destroy
```
This will cleanly terminate all VM instances, tear down VPC subnets, and remove the locally generated SSH private key.
