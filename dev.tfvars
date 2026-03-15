environment        = "dev"
region             = "ap-southeast-1"
vpc_cidr           = "172.16.0.0/16"
availability_zones = ["ap-southeast-1a", "ap-southeast-1b"]
public_subnets     = ["172.16.0.0/24", "172.16.1.0/24"]
private_subnets    = ["172.16.2.0/24", "172.16.3.0/24"]
database_subnets   = ["172.16.4.0/24", "172.16.5.0/24"]
instance_type      = "t3.micro"
min_size           = 1
max_size           = 4
desired_capacity   = 2
db_instance_class  = "db.t3.micro"
db_name            = "appdb"
db_username       = "admin"
db_password       = "Passw0rd123"

