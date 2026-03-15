resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.environment}-vpc", Environment = var.environment }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.environment}-public-${count.index + 1}", Environment = var.environment }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = { Name = "${var.environment}-private-${count.index + 1}", Environment = var.environment }
}

resource "aws_subnet" "database" {
  count             = length(var.database_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = { Name = "${var.environment}-db-${count.index + 1}", Environment = var.environment }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.environment}-igw", Environment = var.environment }
}

resource "aws_eip" "nat" {
  count  = length(var.public_subnets)
  domain = "vpc"
  tags   = { Name = "${var.environment}-nat-eip-${count.index + 1}", Environment = var.environment }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnets)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${var.environment}-nat-${count.index + 1}", Environment = var.environment }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.environment}-public-rt", Environment = var.environment }
}

resource "aws_route_table" "private" {
  count  = length(var.private_subnets)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "${var.environment}-private-rt-${count.index + 1}", Environment = var.environment }
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.environment}-db-rt", Environment = var.environment }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "database" {
  count          = length(var.database_subnets)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "lb_logs" {
  bucket        = "${var.environment}-nlb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.environment}-nlb-logs", Environment = var.environment }
}

resource "aws_s3_bucket_policy" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.lb_logs.arn}/${var.environment}-nlb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.lb_logs.arn
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

resource "aws_eip" "nlb" {
  count  = length(var.public_subnets)
  domain = "vpc"
  tags   = { Name = "${var.environment}-nlb-eip-${count.index + 1}", Environment = var.environment }
}

resource "aws_lb" "network" {
  name                             = "${var.environment}-nlb"
  internal                         = false
  load_balancer_type               = "network"
  enable_deletion_protection       = var.environment == "prod" ? true : false
  enable_cross_zone_load_balancing = true

  subnet_mapping {
    subnet_id     = aws_subnet.public[0].id
    allocation_id = aws_eip.nlb[0].id
  }

  subnet_mapping {
    subnet_id     = aws_subnet.public[1].id
    allocation_id = aws_eip.nlb[1].id
  }

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.id
    prefix  = "${var.environment}-nlb"
    enabled = true
  }

  depends_on = [
    aws_s3_bucket_policy.lb_logs,
    aws_eip.nlb,         
    aws_subnet.public
  ]

  tags = { Name = "${var.environment}-nlb", Environment = var.environment }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.environment}-app-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }
}

resource "aws_lb_listener" "tcp" {
  load_balancer_arn = aws_lb.network.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}