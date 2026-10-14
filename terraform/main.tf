data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}

# Latest Amazon Linux 2023 AMI
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

############################
# Networking
############################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-private-subnet" }
}

# NAT gateway: lets the private instance pull Docker images / packages (outbound only)
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "${var.project_name}-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Free S3 gateway endpoint: app bundle download stays on the AWS network
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.project_name}-s3-endpoint" }
}

############################
# Security groups
############################
resource "aws_security_group" "proxy" {
  name        = "${var.project_name}-proxy-sg"
  description = "Public entry point: HTTP from anywhere, SSH from admin IP only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-proxy-sg" }
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Private app host: only reachable from the proxy/bastion"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-app-sg" }
}

# ---- proxy / bastion ingress
resource "aws_vpc_security_group_ingress_rule" "proxy_http" {
  security_group_id = aws_security_group.proxy.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "proxy_ssh" {
  security_group_id = aws_security_group.proxy.id
  description       = "SSH from the specified admin IP only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

# ---- proxy / bastion egress
resource "aws_vpc_security_group_egress_rule" "proxy_to_app_http" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "Forward HTTP to the app host"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_app_ssh" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "SSH jump to the app host"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "proxy_https_out" {
  security_group_id = aws_security_group.proxy.id
  description       = "HTTPS out (package install)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "proxy_http_out" {
  security_group_id = aws_security_group.proxy.id
  description       = "HTTP out (package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- app ingress (ONLY from proxy SG)
resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from proxy only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.proxy.id
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  security_group_id            = aws_security_group.app.id
  description                  = "SSH from bastion only"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.proxy.id
}

# ---- app egress (via NAT)
resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS out (Docker Hub, GitHub, S3, dnf)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP out (package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

############################
# App bundle -> S3 (private instance downloads it at boot)
############################
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.module}/../app"
  output_path = "${path.module}/.build/app.zip"
  excludes    = [".env", "node_modules"]
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project_name}-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "app" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "app.zip"
  source = data.archive_file.app.output_path
  etag   = data.archive_file.app.output_md5
}

############################
# IAM for the private instance (read the bundle, SSM optional)
############################
resource "aws_iam_role" "app" {
  name = "${var.project_name}-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "app_s3" {
  name = "read-app-bundle"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/app.zip"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app.name
}

############################
# EC2 instances
############################
# Private instance: runs the Docker containers
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.app_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  associate_public_ip_address = false
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/app_user_data.sh.tpl", {
    bucket      = aws_s3_bucket.artifacts.id
    region      = var.region
    db_password = var.db_password
    bundle_md5  = data.archive_file.app.output_md5
  })

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # containers may need metadata
  }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_nat_gateway.nat, aws_route_table_association.private, aws_s3_object.app]
  tags       = { Name = "${var.project_name}-app-private" }
}

# Public instance: nginx reverse proxy + SSH bastion
resource "aws_instance" "proxy" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.public_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/proxy_user_data.sh.tpl", {
    app_private_ip = aws_instance.app.private_ip
  })

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.project_name}-proxy-public" }
}

# Stable public address
resource "aws_eip" "proxy" {
  domain     = "vpc"
  instance   = aws_instance.proxy.id
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.project_name}-proxy-eip" }
}
