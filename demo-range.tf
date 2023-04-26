terraform {
  required_version = ">=1.2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.64.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.3.0"
    }
  }
}

###############################################################################
# PROVIDERS
###############################################################################

provider "aws" {
  region = lookup(var.awsprops, "region")
}

provider "tls" {}
provider "local" {}

###############################################################################
# VARIABLES
###############################################################################

variable "awsprops" {
  type = map(string)
  default = {
    region       = "us-east-2"
    zone         = "a"
    itype        = "m5.large"
    vpccidr      = "172.16.0.0/16"
    secgroupname = "demo-server-sec-group"
    key_name     = "demo-server-key"
  }
}

###############################################################################
# LOCALS
###############################################################################

locals {
  az                     = format("%s%s", lookup(var.awsprops, "region"), lookup(var.awsprops, "zone"))
  vpc_cidr_block         = lookup(var.awsprops, "vpccidr")
  demo_subnet            = cidrsubnet(local.vpc_cidr_block, 8, 10) //172.16.10.0/24
  demo_server_private_ip = cidrhost(local.demo_subnet, 10)         //172.16.10.10

  user_data = <<EOF
#!/bin/bash

apt-get update
apt-get install make sqlite docker.io git awscli unzip -y

cd /opt || return
git clone https://github.com/jonschipp/ISLET.git

cd ISLET || return 
make user-config && make install && make security-config

cd /opt || return 
mkdir /opt/{files,labs,build,extracted}

until [ -s /opt/source.zip ]; do
  aws s3 cp s3://demo-range-bucket-0000/source.zip /opt/
  sleep 1
done

unzip /opt/source.zip -d /opt/extracted/

cp /opt/extracted/environments/* /etc/islet/environments/
cp /opt/extracted/files/* /opt/files/
cp /opt/extracted/labs/* /opt/labs/
cp /opt/extracted/build/* /opt/build/

cd /opt/build || return
[[ -f "/opt/build/Dockerfile" ]] && docker build -t baseimage -f /opt/build/Dockerfile .
[[ -f "/opt/build/Dockerfile.systemd" ]] && docker build -t systemd -f /opt/build/Dockerfile.systemd .

chmod 666 /var/tmp/islet.db

for lab in $(ls /etc/islet/environments/); do echo 'ENABLE="yes"' >> /etc/islet/environments/$lab; done

systemctl restart isletd

EOF
}

###############################################################################
# Archive
###############################################################################

data "archive_file" "demo_source_files" {
  type        = "zip"
  source_dir  = "source/"
  output_path = "generated/source.zip"
}

###############################################################################
# s3
###############################################################################

resource "aws_s3_bucket" "demo" {
  bucket = "demo-range-bucket-0000"

  tags = {
    Name = "demo-bucket"
  }
}

resource "aws_s3_object" "demo_source_zip" {
  bucket = aws_s3_bucket.demo.id
  key    = "source.zip"
  source = data.archive_file.demo_source_files.output_path

  depends_on = [
    data.archive_file.demo_source_files
  ]
}

###############################################################################
# IAM
###############################################################################

resource "aws_iam_role" "demo_iam_role" {
  name               = "demo_iam_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "demo_instance_profile" {
  name = "demo_instance_profile"
  role = aws_iam_role.demo_iam_role.name
}

resource "aws_iam_role_policy" "demo_iam_role_policy" {
  name   = "demo_iam_role_policy"
  role   = aws_iam_role.demo_iam_role.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${aws_s3_bucket.demo.id}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": ["arn:aws:s3:::${aws_s3_bucket.demo.id}/*"]
    }
  ]
}
EOF
}

###############################################################################
# AMI LOOKUP
###############################################################################

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

###############################################################################
# NETWORKING
###############################################################################

resource "aws_vpc" "demo_vpc" {
  cidr_block = local.vpc_cidr_block

  tags = {
    Name = "demo-range-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.demo_vpc.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.demo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "demo-range-route"
  }
}

resource "aws_subnet" "demo_subnet" {
  vpc_id            = aws_vpc.demo_vpc.id
  cidr_block        = local.demo_subnet
  availability_zone = local.az

  tags = {
    Name = "demo-range-subnet"
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.demo_subnet.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_eip" "eip" {
  vpc = true
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.demo-server.id
  allocation_id = aws_eip.eip.id
}

###############################################################################
# SECURITY GROUP
###############################################################################

resource "aws_security_group" "demo-server-sg" {
  name        = lookup(var.awsprops, "secgroupname")
  description = lookup(var.awsprops, "secgroupname")
  vpc_id      = aws_vpc.demo_vpc.id

  ingress {
    from_port   = 22
    protocol    = "tcp"
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# SSH 
###############################################################################

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = lookup(var.awsprops, "key_name")
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "private_key.pem"
  file_permission = "0600"
}

###############################################################################
# AWS INSTANCE  demo-server
###############################################################################

resource "aws_instance" "demo-server" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = lookup(var.awsprops, "itype")
  subnet_id            = aws_subnet.demo_subnet.id
  private_ip           = local.demo_server_private_ip
  key_name             = aws_key_pair.generated_key.key_name
  iam_instance_profile = aws_iam_instance_profile.demo_instance_profile.id
  user_data            = local.user_data

  vpc_security_group_ids = [
    aws_security_group.demo-server-sg.id
  ]

  root_block_device {
    volume_size = 50
  }
  tags = {
    Name = "demo-server"
  }

  depends_on = [
    aws_security_group.demo-server-sg,
    aws_internet_gateway.igw,
    aws_s3_object.demo_source_zip,
  ]
}

###############################################################################
# OUTPUTS
###############################################################################

output "instructions" {
  value = <<EOF
Access the server:

Admin:
  ssh -i ./private_key.pem ubuntu@${aws_eip.eip.public_ip}

ISLET User:
  ssh demo@${aws_eip.eip.public_ip}
   - pw: demo
EOF
}
