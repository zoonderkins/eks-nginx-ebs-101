# EKS Cluster with Nginx and Persistent Storage

This Terraform project creates an EKS cluster with the following components:
- VPC with public and private subnets
- EKS cluster with a single worker node
- AWS EBS CSI Driver for storage
- Nginx deployment with 1 pod
- 20GB EBS volume mounted to the Nginx pod at `/data`

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- kubectl
- helm

## Usage

1. Initialize Terraform:
```bash
terraform init
```

2. Review the planned changes:
```bash
terraform plan
```

3. Apply the configuration:
```bash
terraform apply
```

4. Configure kubectl to use the new cluster:
```bash
aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)
```

5. Verify the deployment:
```bash
kubectl get pods
kubectl get pvc
kubectl get sc
```

## Clean Up

To destroy all resources:
```bash
terraform destroy
```

## Configuration

The following variables can be customized in `variables.tf` or through a tfvars file:
- `region`: AWS region (default: us-west-2)
- `cluster_name`: Name of the EKS cluster (default: demo-eks-cluster)
- `vpc_cidr`: CIDR block for VPC (default: 10.0.0.0/16)
- `environment`: Environment name (default: demo) 


## Git 

```bash
git config --local user.name zoonderkins                                                                                  
git config --local user.email git-ed@runbox.no
