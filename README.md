# AWS 3-Tier Architecture — Debugging Guide

A full record of every command used to debug and fix the 3-tier Terraform infrastructure.

---

## Architecture Overview

```
Internet
    │
    ▼
ALB (public subnets 1a/1b)          ← Tier 1
    │  HTTP:80
    ▼
EC2 ASG (private subnets 1a/1b)     ← Tier 2
    │  MySQL:3306
    ▼
RDS MySQL (db subnets 1a/1b)        ← Tier 3
```

---

## Root Causes Summary

| # | Problem | Cause | Fix |
|---|---------|-------|-----|
| 1 | NLB health checks failing | NLB has no SG — private SG blocked NLB traffic | Allow VPC CIDR on port 80 in private SG |
| 2 | Wrong AMI | AMI filter too loose, returned Ubuntu instead of Amazon Linux 2 | Add `virtualization-type` and `state` filters |
| 3 | httpd not running | `yum` doesn't exist on Ubuntu, install silently failed | Fix AMI or use `apt-get` |
| 4 | NLB `Addresses: []` | No EIPs pinned to NLB nodes | Use `subnet_mapping` with `aws_eip` |
| 5 | NLB can't be modified in-place | AWS doesn't allow changing subnet mappings on existing NLB | Delete and recreate NLB |
| 6 | Port 80 blocked locally | ISP/router blocks outbound port 80 | Switch to ALB (simpler, supports SGs) |
| 7 | ALB S3 logs permission denied | ALB needs regional ELB account ARN, not just service principal | Add `aws_elb_service_account` to bucket policy |

---

## Terraform Commands

### Initialise and validate

```bash
terraform init
terraform validate
terraform plan
terraform apply
terraform destroy
```

### Force recreate specific resources

```bash
terraform apply -replace='module.vpc.aws_lb.network'
terraform apply -replace='module.vpc.aws_lb_listener.tcp'
terraform apply -replace='module.vpc.aws_lb_target_group.app'
terraform apply -replace='module.ec2_instances.aws_launch_template.main'
terraform apply -replace='module.ec2_instances.aws_autoscaling_group.main'
```

### State management

```bash
# list all resources in state
terraform state list

# remove resource from state (without deleting from AWS)
terraform state rm module.vpc.aws_lb.network
terraform state rm module.vpc.aws_lb_listener.tcp
terraform state rm module.vpc.aws_lb_target_group.app
terraform state rm 'module.vpc.aws_eip.nlb[0]'
terraform state rm 'module.vpc.aws_eip.nlb[1]'

# import existing AWS resource into state
terraform import module.vpc.aws_lb_target_group.app <target-group-arn>

# force unlock stuck state
terraform force-unlock <lock-id>

# delete lock file directly from S3
aws s3 rm s3://<bucket>/3tier/terraform.tfstate.tflock --region ap-southeast-1

# inspect a specific resource in state
terraform state show module.vpc.aws_lb.network
terraform state show module.ec2_instances.aws_autoscaling_group.main | grep target_group
```

### Outputs

```bash
terraform output
terraform output -raw alb_dns_name
terraform output nlb_public_ips
```

---

## S3 State Backend

```bash
# create state bucket
aws s3api create-bucket \
  --bucket <bucket-name> \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

# enable versioning
aws s3api put-bucket-versioning \
  --bucket <bucket-name> \
  --versioning-configuration Status=Enabled

# block public access
aws s3api put-public-access-block \
  --bucket <bucket-name> \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

---

## EC2 and ASG Commands

```bash
# list instances with AZ and subnet
aws ec2 describe-instances \
  --filters "Name=tag:Environment,Values=dev" \
  --region ap-southeast-1 \
  --query 'Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,Subnet:SubnetId,PrivateIP:PrivateIpAddress}'

# get all instance IDs in ASG
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names dev-asg \
  --region ap-southeast-1 \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text

# terminate all instances in ASG (ASG replaces them automatically)
aws ec2 terminate-instances \
  --instance-ids $(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names dev-asg \
    --region ap-southeast-1 \
    --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
    --output text) \
  --region ap-southeast-1

# check ASG scaling activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name dev-asg \
  --region ap-southeast-1 \
  --query 'Activities[0:5].{Status:StatusCode,Cause:Cause}' \
  --output table

# check ASG target group ARNs
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names dev-asg \
  --region ap-southeast-1 \
  --query 'AutoScalingGroups[0].{TGARNs:TargetGroupARNs,Instances:Instances[*].{ID:InstanceId,State:LifecycleState}}'

# suspend ASG health check replacements (useful while debugging)
aws autoscaling suspend-processes \
  --auto-scaling-group-name dev-asg \
  --scaling-processes HealthCheck ReplaceUnhealthy \
  --region ap-southeast-1

# resume ASG processes
aws autoscaling resume-processes \
  --auto-scaling-group-name dev-asg \
  --scaling-processes HealthCheck ReplaceUnhealthy \
  --region ap-southeast-1
```

---

## Load Balancer Commands

```bash
# get ALB DNS name
aws elbv2 describe-load-balancers \
  --names dev-alb \
  --region ap-southeast-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text

# check ALB state and scheme
aws elbv2 describe-load-balancers \
  --names dev-alb \
  --region ap-southeast-1 \
  --query 'LoadBalancers[0].{Scheme:Scheme,Type:Type,State:State.Code}'

# check ALB attributes
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names dev-alb \
    --region ap-southeast-1 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text) \
  --region ap-southeast-1

# disable deletion protection
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names dev-alb \
    --region ap-southeast-1 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text) \
  --attributes Key=deletion_protection.enabled,Value=false \
  --region ap-southeast-1

# enable cross-zone load balancing
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names dev-alb \
    --region ap-southeast-1 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text) \
  --attributes Key=load_balancing.cross_zone.enabled,Value=true \
  --region ap-southeast-1

# delete load balancer
aws elbv2 delete-load-balancer \
  --load-balancer-arn <arn> \
  --region ap-southeast-1

# wait for LB to be fully deleted
aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns <arn> \
  --region ap-southeast-1
```

---

## Target Group and Health Check Commands

```bash
# get target group ARN
aws elbv2 describe-target-groups \
  --names dev-app-tg \
  --region ap-southeast-1 \
  --query 'TargetGroups[0].{ARN:TargetGroupArn,LBArns:LoadBalancerArns}'

# check target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names dev-app-tg \
    --region ap-southeast-1 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region ap-southeast-1 \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table

# watch target health (refreshes every 15 seconds)
watch -n 15 "aws elbv2 describe-target-health \
  --target-group-arn \$(aws elbv2 describe-target-groups \
    --names dev-app-tg \
    --region ap-southeast-1 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region ap-southeast-1 \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}' \
  --output table"

# check listeners
aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names dev-alb \
    --region ap-southeast-1 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text) \
  --region ap-southeast-1 \
  --query 'Listeners[*].{Port:Port,Protocol:Protocol,TG:DefaultActions[0].TargetGroupArn}'

# delete target group
aws elbv2 delete-target-group \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names dev-app-tg \
    --region ap-southeast-1 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --region ap-southeast-1
```

---

## VPC and Networking Commands

```bash
# check route tables
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --region ap-southeast-1 \
  --query 'RouteTables[*].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[*].{Dest:DestinationCidrBlock,Target:NatGatewayId}}' \
  --output table

# verify route table is associated with public subnets
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=<subnet-id-1>,<subnet-id-2>" \
  --region ap-southeast-1 \
  --query 'RouteTables[*].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[*].{Dest:DestinationCidrBlock,GW:GatewayId}}'

# check NACLs
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --region ap-southeast-1 \
  --query 'NetworkAcls[*].{ID:NetworkAclId,Inbound:Entries[?Egress==`false`],Outbound:Entries[?Egress==`true`]}'

# check security group rules
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=dev-private-sg" \
  --region ap-southeast-1 \
  --query 'SecurityGroups[0].IpPermissions'

# add ingress rule to security group
aws ec2 authorize-security-group-ingress \
  --group-id <sg-id> \
  --protocol tcp \
  --port 80 \
  --cidr 172.16.0.0/16 \
  --region ap-southeast-1

# check subnets
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=dev-public-*" \
  --region ap-southeast-1 \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`]|[0].Value,ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}'

# check available IPs in subnet
aws ec2 describe-subnets \
  --subnet-ids <subnet-id-1> <subnet-id-2> \
  --region ap-southeast-1 \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`]|[0].Value,Available:AvailableIpAddressCount,CIDR:CidrBlock}'

# check EIP allocations
aws ec2 describe-addresses \
  --region ap-southeast-1 \
  --query 'Addresses[*].{IP:PublicIp,AssociationId:AssociationId,AllocationId:AllocationId,NetworkInterfaceId:NetworkInterfaceId}' \
  --output table

# release EIP
aws ec2 release-address \
  --allocation-id <allocation-id> \
  --region ap-southeast-1

# check NLB network interfaces
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=*ELB*dev-nlb*" \
  --region ap-southeast-1 \
  --query 'NetworkInterfaces[*].{AZ:AvailabilityZone,SubnetId:SubnetId,PrivateIP:PrivateIpAddress}' \
  --output table
```

---

## SSM Session Manager Commands

```bash
# install SSM plugin on Ubuntu
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb
session-manager-plugin --version

# add SSM permissions to IAM user
aws iam put-user-policy \
  --user-name <username> \
  --policy-name ssm-session \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": ["ec2:DescribeInstances"],
        "Resource": "*"
      }
    ]
  }'

# connect to instance
aws ssm start-session \
  --target <instance-id> \
  --region ap-southeast-1

# check SSM agent is registered
aws ssm describe-instance-information \
  --region ap-southeast-1 \
  --query 'InstanceInformationList[*].{ID:InstanceId,Ping:PingStatus,Agent:AgentVersion}' \
  --output table
```

---

## Debugging Inside EC2 (via SSM)

```bash
# check httpd status
systemctl status httpd

# check user_data execution log
cat /var/log/cloud-init-output.log | tail -50
cat /var/log/cloud-init-output.log | grep -E "error|Error|failed|Failed|httpd"

# test apache locally
curl -v localhost
curl -v http://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# check what's listening on port 80
ss -tlnp | grep :80

# get instance metadata
curl http://169.254.169.254/latest/meta-data/instance-id
curl http://169.254.169.254/latest/meta-data/local-ipv4

# test outbound internet (via NAT)
curl --max-time 5 http://checkip.amazonaws.com

# check default route
ip route show

# check DNS resolver
cat /etc/resolv.conf

# test NLB private IPs from inside VPC
curl -v --max-time 10 http://172.16.0.189
curl -v --max-time 10 http://172.16.1.166
```

---

## Local Network Debugging

```bash
# test if port 80 is open outbound
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/93.184.216.34/80' && echo "port 80 OPEN" || echo "port 80 BLOCKED"

# test multiple ports
for port in 80 443 8080 8443 3000; do
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/93.184.216.34/$port" 2>/dev/null \
    && echo "port $port OPEN" \
    || echo "port $port BLOCKED"
done

# test curl to known server
curl -v --max-time 5 http://example.com

# DNS lookup
nslookup <alb-dns-name>
dig <alb-dns-name>

# test ALB endpoint
curl -v --max-time 15 http://<alb-dns-name>
curl http://<alb-dns-name>
```

---

## Accessing EC2 via SSM (No SSH Required)

SSM Session Manager replaces SSH — no key pairs, no open port 22, no bastion host needed.
The EC2 instance must have the `AmazonSSMManagedInstanceCore` IAM policy attached.

```bash
# step 1 — get a running instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Environment,Values=dev" "Name=instance-state-name,Values=running" \
  --region ap-southeast-1 \
  --query 'Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,IP:PrivateIpAddress}' \
  --output table

# step 2 — verify instance is registered with SSM (must show ping status Online)
aws ssm describe-instance-information \
  --region ap-southeast-1 \
  --query 'InstanceInformationList[*].{ID:InstanceId,Ping:PingStatus,Platform:PlatformName}' \
  --output table

# step 3 — start session
aws ssm start-session \
  --target <instance-id> \
  --region ap-southeast-1

# step 4 — you are now inside the instance, run any commands:
whoami
hostname
curl localhost
systemctl status httpd

# step 5 — exit the session
exit
```

### Troubleshooting SSM access

```bash
# error: AccessDeniedException — your IAM user lacks ssm:StartSession
aws iam put-user-policy \
  --user-name <your-iam-username> \
  --policy-name ssm-session \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": ["ec2:DescribeInstances"],
        "Resource": "*"
      }
    ]
  }'

# error: SessionManagerPlugin is not found — install the plugin
# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb

# macOS ARM (M1/M2)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip" \
  -o sessionmanager-bundle.zip
unzip sessionmanager-bundle.zip
sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

# macOS Intel
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" \
  -o sessionmanager-bundle.zip
unzip sessionmanager-bundle.zip
sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

# verify plugin installed correctly
session-manager-plugin --version

# instance not showing in SSM — check IAM profile is attached
aws ec2 describe-instances \
  --instance-ids <instance-id> \
  --region ap-southeast-1 \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'
# if null — instance launched without profile, terminate it and let ASG replace it
```

---

## RDS Commands

```bash
# describe RDS instance
aws rds describe-db-instances \
  --db-instance-identifier dev-db \
  --region ap-southeast-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint,AZ:AvailabilityZone}'
```

---

## Testing EC2 to RDS Connectivity

The EC2 instances in the private subnet should be able to reach RDS on port 3306.
RDS is in the database subnet and only allows traffic from the private security group.

### Step 1 — get the RDS endpoint

```bash
DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier dev-db \
  --region ap-southeast-1 \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "DB endpoint: $DB_ENDPOINT"
```

### Step 2 — SSM into an EC2 instance

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names dev-asg \
  --region ap-southeast-1 \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session \
  --target $INSTANCE_ID \
  --region ap-southeast-1
```

### Step 3 — test connectivity from inside the instance

```bash
# test TCP connection to RDS port 3306
# replace <db-endpoint> with the actual RDS endpoint from step 1
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/<db-endpoint>/3306' \
  && echo "port 3306 OPEN — RDS reachable" \
  || echo "port 3306 BLOCKED — check security group"

# install mysql client if not present
sudo yum install -y mysql

# connect to RDS (you will be prompted for password)
mysql -h <db-endpoint> -u <db-username> -p

# once connected, run basic checks
SHOW DATABASES;
USE appdb;
SHOW TABLES;

# create a test table to verify read/write works
CREATE TABLE IF NOT EXISTS test (
  id INT AUTO_INCREMENT PRIMARY KEY,
  message VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO test (message) VALUES ('hello from ec2');
SELECT * FROM test;
DROP TABLE test;

# exit mysql
exit
```

### Step 4 — verify from the application side

Update `user_data` in `modules/ec2/main.tf` to install mysql client and write a
test PHP or shell script that connects to RDS on startup:

```hcl
user_data = base64encode(<<-EOF
  #!/bin/bash
  yum update -y
  yum install -y httpd mysql

  systemctl enable httpd
  systemctl start httpd

  # write a health page
  echo "Hello from ${var.environment}" > /var/www/html/index.html
  echo "Instance: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)" >> /var/www/html/index.html

  # write a DB connectivity check page
  cat > /var/www/html/db-check.sh <<'SCRIPT'
  #!/bin/bash
  mysql -h ${db_endpoint} -u ${db_username} -p${db_password} \
    -e "SELECT 'DB connection OK' AS status;" 2>&1
  SCRIPT
  chmod +x /var/www/html/db-check.sh
EOF
)
```

### Step 5 — troubleshoot if connection is refused

```bash
# check the DB security group allows port 3306 from the private SG
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=dev-db-sg" \
  --region ap-southeast-1 \
  --query 'SecurityGroups[0].IpPermissions'

# check RDS is in the available state
aws rds describe-db-instances \
  --db-instance-identifier dev-db \
  --region ap-southeast-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Engine:Engine}'

# check RDS subnet group covers both AZs
aws rds describe-db-subnet-groups \
  --db-subnet-group-name dev-db-subnet-group \
  --region ap-southeast-1 \
  --query 'DBSubnetGroups[0].Subnets[*].{AZ:SubnetAvailabilityZone.Name,ID:SubnetIdentifier}'

# verify the instance SG and DB SG are correctly linked
# instance must be in dev-private-sg
# dev-db-sg must allow port 3306 from dev-private-sg
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=dev-private-sg" \
  --region ap-southeast-1 \
  --query 'SecurityGroups[0].{ID:GroupId,Name:GroupName}'
```

---

## Key Lessons Learned

**NLB vs ALB for HTTP workloads:**
- NLB operates at Layer 4 (TCP) — no security group support, harder to debug HTTP issues
- ALB operates at Layer 7 (HTTP) — supports security groups, HTTP health checks, path routing
- For HTTP/HTTPS web traffic, always use ALB

**NLB security group gotcha:**
- NLB has no security group — it forwards traffic using its own private IPs from within the VPC
- You cannot use `security_groups = [sg-id]` to allow NLB traffic — you must allow the full VPC CIDR

**AMI filter best practice:**
- Always add `virtualization-type = hvm` and `state = available` filters
- A loose filter can return the wrong OS entirely

**Terraform state tips:**
- Use `terraform state rm` + manual AWS delete when resources get into an inconsistent state
- Use `terraform import` to bring existing AWS resources back under Terraform management
- Never use `-lock=false` — use `force-unlock` or delete the `.tflock` file from S3 instead

**S3 bucket policy for load balancer logs:**
- NLB access logs → use `delivery.logs.amazonaws.com` service principal
- ALB access logs → use `aws_elb_service_account` data source (regional ELB account ARN)

**user_data debugging:**
- Always check `/var/log/cloud-init-output.log` when instances behave unexpectedly
- Instances in private subnets need NAT Gateway to be ready before `yum install` works
- Use `depends_on` in the ASG to wait for NAT Gateways

---

## Final Working Test

```bash
curl http://$(aws elbv2 describe-load-balancers \
  --names dev-alb \
  --region ap-southeast-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# expected output:
# Hello from dev
# Instance: i-xxxxxxxxxxxxxxxxx
```