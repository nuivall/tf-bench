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

### Step 2: Initialize Database Schema
Run Latte's schema creation routine to create the `latte` keyspace (replicated with a replication factor of 3 across the subnets) and the `bench` table:
```bash
latte schema workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```

### Step 3: Pre-populate Database
Load 1,000,000 rows into the table before performing reads or mixed tests. This ensures a consistent, representative dataset:
```bash
latte run -f load -d 1000000 --threads 8 --concurrency 64 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```

### Step 4: Run Steady-State 50/50 Mixed Workload
Execute a 50/50 mix ofpoint reads and point writes. Latte will concurrently schedule 50% reads and 50% writes and log their latency percentiles and throughput separately:
```bash
latte run -f read:0.5 -f write:0.5 -d 10m --threads 8 --concurrency 64 workloads/workload.rn <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```
* **`threads`**: Maps to client-side runner cores.
* **`concurrency`**: Defines active concurrent asynchronous queries per thread.
* **`d 10m`**: Runs the benchmark for 10 minutes.

### Step 5: Simulate a Connection Storm
A client-driver maintains persistent connection pools. To test how Scylla handles a massive scale-up or server reboot connection storm, run our custom storm generator in another terminal (or background it):
```bash
./workloads/connect_storm.sh <scylla-ip-1> <scylla-ip-2> <scylla-ip-3>
```
This script constantly loops and spawns multiple short-lived concurrent `latte run` commands, flooding the Scylla coordinators with up to **2,500 connections per second** to establish, authenticate, point-query, and drop.

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
