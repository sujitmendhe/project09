resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }

}

resource "aws_security_group" "sg" {
  name   = "allow_all"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow all inbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }

}

# elastic ip
resource "aws_eip" "nat" {
  domain = "vpc"
}

# Nat Gateway in public subnet
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

}

# Private route table
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

}

# private subnet association with nat gateway
resource "aws_route_table_association" "private_sub" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt.id

}

# data block for subnets
data "aws_availability_zones" "available" {
  state = "available"

}

# Subnets (2 Public, 2 private)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "public-subnet-${count.index}"
  }

}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 2}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

# Route table for public subnet

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

}

# Route table association

resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "my_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "Lambda.amazonaws.com" }
    }]
  })
}

# attching policy to role
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

}

# lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "lambda_function_payload.zip"
}

resource "aws_lambda_function" "my_lmbda" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "my_vpc_lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.sg.id]
  }
}

data "aws_ami" "latest" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# generate a secure private key

resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "name" {
  key_name   = "k8-key"
  public_key = tls_private_key.main.public_key_openssh
}

resource "local_file" "name" {
  filename        = "${path.module}/k8-key.pem"
  content         = tls_private_key.main.private_key_pem
  file_permission = "0400"

}

resource "aws_instance" "k8_private" {
  ami                    = data.aws_ami.latest.id
  instance_type          = "t2.medium"
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.sg.id]
  key_name               = aws_key_pair.name.key_name
  user_data              = file("${path.module}/script.sh")

  tags = {
    Name = "k8-server-private"
  }

}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.latest.id
  instance_type               = "t3.micro" # Bastion doesn't need much power
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.sg.id]
  associate_public_ip_address = true

  # Using the same key pair we generated earlier
  key_name = aws_key_pair.name.key_name

  tags = {
    Name = "Public-Bastion-Host"
  }
}