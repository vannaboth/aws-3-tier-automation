![infra](https://camo.githubusercontent.com/26930e9910e25d128b4747c7b8d3105d0c6180f6ed9d0a42ec77cb63ee1ab878/68747470733a2f2f696d6775722e636f6d2f623969487756632e706e67)

## Create s3 bucket to store state file
```shell
aws s3api create-bucket \
  --bucket dev-terrraform-state \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1
```

## Run terraform
```shell
terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

> [!NOTE]
> Use the dev.tfvars to input values.