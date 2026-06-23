terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Keep  = "3"
      Owner = "marcinmal"
    }
  }
}

# 1. SSH Key Pair Generation
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key_pair" {
  key_name   = "${var.cluster_name}-key"
  public_key = tls_private_key.key.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "${path.module}/${var.cluster_name}-key.pem"
  file_permission = "0600"
}

# 2. VPC and Multi-AZ Subnets
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "subnet" {
  count                   = 3
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-subnet-${count.index}"
  }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.cluster_name}-rt"
  }
}

resource "aws_route_table_association" "rta" {
  count          = 3
  subnet_id      = aws_subnet.subnet[count.index].id
  route_table_id = aws_route_table.rt.id
}

# 3. Security Groups
resource "aws_security_group" "scylla" {
  name        = "${var.cluster_name}-scylla-sg"
  description = "Security group for ScyllaDB cluster nodes"
  vpc_id      = aws_vpc.vpc.id

  # SSH Access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  # CQL Client Native Protocol
  ingress {
    from_port   = 9042
    to_port     = 9042
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr, "10.0.0.0/16"]
  }

  # Prometheus scrape port
  ingress {
    from_port   = 9180
    to_port     = 9180
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Node Exporter metrics port
  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Internal Scylla node-to-node communication
  ingress {
    from_port   = 7000
    to_port     = 7001
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 7000
    to_port     = 7001
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Outbound rules
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-scylla-sg"
  }
}

resource "aws_security_group" "loader" {
  name        = "${var.cluster_name}-loader-sg"
  description = "Security group for Latte Loaders"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-loader-sg"
  }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.cluster_name}-monitoring-sg"
  description = "Security group for Scylla Monitoring node"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  # Grafana Dashboard
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  # Prometheus UI
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-monitoring-sg"
  }
}

# 4. AMIs (Ubuntu 22.04 LTS for Scylla, Ubuntu 24.04 LTS for Client/Monitor)
data "aws_ami" "ubuntu_22" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

data "aws_ami" "ubuntu_24" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# 5. EC2 Instances
resource "aws_instance" "scylla" {
  count                  = 3
  ami                    = data.aws_ami.ubuntu_22.id
  instance_type          = var.scylla_instance_type
  subnet_id              = aws_subnet.subnet[count.index].id
  private_ip             = "10.0.${count.index + 1}.50"
  vpc_security_group_ids = [aws_security_group.scylla.id]
  key_name               = aws_key_pair.key_pair.key_name

  user_data = templatefile("${path.module}/user_data/scylla.sh.tpl", {
    cluster_name    = var.cluster_name
    scylla_version  = var.scylla_version
    seed_ip         = "10.0.1.50"
    read_iops       = lookup(local.io_properties, var.scylla_instance_type, local.io_properties["default"]).read_iops
    read_bandwidth  = lookup(local.io_properties, var.scylla_instance_type, local.io_properties["default"]).read_bandwidth
    write_iops      = lookup(local.io_properties, var.scylla_instance_type, local.io_properties["default"]).write_iops
    write_bandwidth = lookup(local.io_properties, var.scylla_instance_type, local.io_properties["default"]).write_bandwidth
  })

  tags = {
    Name = "${var.cluster_name}-scylla-${count.index}"
  }
}

resource "aws_instance" "loader" {
  count                  = var.loader_count
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = var.loader_instance_type
  subnet_id              = aws_subnet.subnet[count.index % 3].id
  vpc_security_group_ids = [aws_security_group.loader.id]
  key_name               = aws_key_pair.key_pair.key_name

  user_data = templatefile("${path.module}/user_data/loader.sh.tpl", {
    workload_rn_content   = file("${path.module}/../workloads/workload.rn")
    connect_storm_content = file("${path.module}/../workloads/connect_storm.sh")
    run_benchmark_content = file("${path.module}/../workloads/run_benchmark.sh")
  })

  tags = {
    Name = "${var.cluster_name}-loader-${count.index}"
  }
}

locals {
  scylla_servers_yaml = <<EOF
- targets:
${join("\n", [for ip in ["10.0.1.50", "10.0.2.50", "10.0.3.50"] : "  - ${ip}:9180"])}
  labels:
    cluster: ${var.cluster_name}
EOF
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = var.monitoring_instance_type
  subnet_id              = aws_subnet.subnet[0].id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  key_name               = aws_key_pair.key_pair.key_name

  user_data = templatefile("${path.module}/user_data/monitoring.sh.tpl", {
    scylla_servers_yaml = local.scylla_servers_yaml
    scylla_version      = var.scylla_version
  })

  tags = {
    Name = "${var.cluster_name}-monitoring"
  }
}
