variable "aws_region" {
  description = "AWS region to provision the benchmark in"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "The name of the ScyllaDB cluster"
  type        = string
  default     = "tf-scylla-benchmark"
}

variable "scylla_instance_type" {
  description = "EC2 instance type for Scylla DB nodes (needs NVMe instance storage for I/O tuning). Default i4i.large: 2 vCPU x86 (Intel Ice Lake) with local NVMe SSD; provisions faster than ARM i8g."
  type        = string
  default     = "i4i.large"
}

variable "loader_count" {
  description = "Number of distributed Latte loader nodes to provision. More nodes = more independent ephemeral-port pools, file-descriptor budgets, and source IPs, which is the main lever for high new-connection-per-second floods. Raised 12 -> 18 (+50%) to push the aggregate new-connection arrival rate past the per-shard threshold that triggers scylla_transport_connections_shed."
  type        = number
  default     = 18
}

variable "loader_instance_type" {
  description = "EC2 instance type for Loader nodes (compute-optimized)"
  type        = string
  default     = "c5.xlarge"
}

variable "monitoring_instance_type" {
  description = "EC2 instance type for the Scylla Monitoring node (cost-optimized)"
  type        = string
  default     = "t3.small"
}

variable "scylla_version" {
  description = "ScyllaDB version to install and matching Grafana dashboard set (e.g. 2026.2, 2026.1, 6.0)"
  type        = string
  default     = "2026.2"
}

variable "trusted_cidr" {
  description = "CIDR block allowed to SSH, access Grafana, and access Prometheus. Set to your public IP for safety."
  type        = string
  default     = "0.0.0.0/0"
}

# Precalculated I/O Properties map to bypass slow iotune benchmark
locals {
  io_properties = {
    # i4i.large: 2 vCPU x86 (Intel Ice Lake), 1x 468GB local AWS Nitro NVMe SSD.
    # Precalculated to skip the ~15-min iotune run. Values are for the single
    # NVMe device on the .large size (roughly half of i4i.xlarge's throughput).
    "i4i.large" = {
      read_iops       = 200000
      read_bandwidth  = 1100000000
      write_iops      = 60000
      write_bandwidth = 550000000
    }
    "i3en.xlarge" = {
      read_iops       = 240000
      read_bandwidth  = 1200000000
      write_iops      = 110000
      write_bandwidth = 600000000
    }
    "i3.xlarge" = {
      read_iops       = 115000
      read_bandwidth  = 620000000
      write_iops      = 35000
      write_bandwidth = 210000000
    }
    "im4gn.xlarge" = {
      read_iops       = 270000
      read_bandwidth  = 1600000000
      write_iops      = 90000
      write_bandwidth = 750000000
    }
    "default" = {
      read_iops       = 3000
      read_bandwidth  = 125000000
      write_iops      = 3000
      write_bandwidth = 125000000
    }
  }
}
