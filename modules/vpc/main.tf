# Define the VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${terraform.workspace}-vpc"
  }
}

# Create an Internet Gateway for the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${terraform.workspace}-igw"
  }

  depends_on = [aws_vpc.main] # Ensure IGW is created after VPC
}

# Public Subnets
resource "aws_subnet" "public_subnet" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  map_public_ip_on_launch = true
  availability_zone       = element(var.availability_zones, count.index)

  tags = {
    Name                    = "${terraform.workspace}-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
  }

  depends_on = [aws_vpc.main] # Ensure subnet is created after VPC
}

# Private Subnets
resource "aws_subnet" "private_subnet" {
  count             = length(var.private_subnets)
  vpc_id           = aws_vpc.main.id
  cidr_block       = var.private_subnets[count.index]
  availability_zone = element(var.availability_zones, count.index)

  tags = {
    Name                               = "${terraform.workspace}-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }

  depends_on = [aws_vpc.main] # Ensure subnet is created after VPC
}

# Allocate an Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.igw] # Ensure Elastic IP is created after IGW
}

# Create NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet[0].id

  tags = {
    Name = "${terraform.workspace}-nat"
  }

  depends_on = [aws_subnet.public_subnet, aws_eip.nat] # Ensure NAT Gateway is created after EIP and Public Subnet
}

# Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${terraform.workspace}-public-rt"
  }

  depends_on = [aws_internet_gateway.igw] # Ensure route table is created after IGW
}

# Private Route Table
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${terraform.workspace}-private-rt"
  }

  depends_on = [aws_nat_gateway.nat] # Ensure route table is created after NAT Gateway
}

# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_assoc" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt.id

  depends_on = [aws_route_table.public_rt, aws_subnet.public_subnet] # Ensure association is after route table and subnet
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_assoc" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_rt.id

  depends_on = [aws_route_table.private_rt, aws_subnet.private_subnet] # Ensure association is after route table and subnet
}

