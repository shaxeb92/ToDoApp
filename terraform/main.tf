# terraform/main.tf → FINAL 100% WORKING VERSION (NO ERRORS)

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"    # US East (N. Virginia) = super fast + GDPR
}

# 1. Your own VPC
resource "aws_vpc" "todo_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "todoapp-vpc" }
}

# 2. Internet Gateway + Route Table (REQUIRED)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.todo_vpc.id
  tags   = { Name = "todo-igw" }
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.todo_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "todo-public-rt" }
}

# THIS IS THE FIX: Make the default route table the main one → automatically applies to ALL default subnets
resource "aws_main_route_table_association" "main" {
  vpc_id         = aws_vpc.todo_vpc.id
  route_table_id = aws_route_table.public.id
}

# 3. ECR
resource "aws_ecr_repository" "todo_app" {
  name                 = "devops-todo-app"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

# 4. IAM Roles (fixed & complete)
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role" "eks_nodes" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = {
    a = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    b = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    c = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  }
  policy_arn = each.value
  role       = aws_iam_role.eks_nodes.name
}


# 1. Create at least 2 subnets in different AZs
resource "aws_subnet" "eks_subnet" {
  count = 2

  vpc_id            = aws_vpc.todo_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.todo_vpc.cidr_block, 4, count.index)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  map_public_ip_on_launch = true

  tags = {
    Name = "eks-subnet-${element(data.aws_availability_zones.available.names, count.index)}"
    "kubernetes.io/cluster/devops-eks" = "shared"
    "kubernetes.io/role/elb"           = "1"
  }
}

# 2. Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# 3. EKS Cluster using the NEW subnets
resource "aws_eks_cluster" "devops_eks" {
  name     = "devops-eks"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.eks_subnet[*].id
    endpoint_private_access = false
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}


# ====== ADD THIS: EKS MANAGED NODE GROUP ======
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.devops_eks.name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.eks_subnet[*].id

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  # Optional: Use launch template for custom AMI, etc.
  # launch_template { ... }

  # Ensures nodes join cluster only after policies are attached
  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes
  ]
}

# OUTPUTS
output "ecr_url" {
  value = aws_ecr_repository.todo_app.repository_url
}

output "cluster_name" {
  value = aws_eks_cluster.devops_eks.name
}

output "connect_command" {
  value = "aws eks update-kubeconfig --name devops-eks --region us-east-1"
}

output "app_url_in_5_minutes" {
  value = "After git push → run: kubectl get svc todo-service -o wide"
}