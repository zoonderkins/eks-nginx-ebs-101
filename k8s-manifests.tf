# Add data source to get AWS account ID
data "aws_caller_identity" "current" {}

# First, add the EBS CSI driver IAM role
resource "aws_iam_role" "ebs_csi_driver" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

# Attach the required AWS-managed policy
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

# Comment out EFS CSI driver IAM role
/*
# EFS CSI driver IAM role
resource "aws_iam_role" "efs_csi_driver" {
  name = "AmazonEKS_EFS_CSI_DriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

# Attach the required AWS-managed policy for EFS CSI Driver
resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_csi_driver.name
}

# Create EFS File System
resource "aws_efs_file_system" "eks" {
  creation_token = "eks-efs"
  encrypted      = true

  tags = {
    Name = "eks-efs"
  }
}

# Create EFS Mount Target (create one per subnet)
resource "aws_efs_mount_target" "eks" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Security Group for EFS
resource "aws_security_group" "efs" {
  name        = "eks-efs"
  description = "Allow EFS inbound traffic from EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS from EKS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Storage Class for EFS
resource "kubernetes_storage_class" "efs_sc" {
  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.eks.id
    directoryPerms   = "700"
  }

  depends_on = [
    module.eks
  ]
}
*/

# Storage Class for EBS
resource "kubernetes_storage_class" "ebs_sc" {
  metadata {
    name = "ebs-sc"
  }
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [
    module.eks
  ]
}

# PVC using EBS
resource "kubernetes_persistent_volume_claim" "nginx_pvc" {
  metadata {
    name      = "nginx-pvc-ebs"
    namespace = "default"
  }
  spec {
    access_modes       = ["ReadWriteOnce"] # EBS supports ReadWriteOnce
    storage_class_name = kubernetes_storage_class.ebs_sc.metadata[0].name
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  depends_on = [
    module.eks,
    kubernetes_storage_class.ebs_sc
  ]

  timeouts {
    create = "5m"
  }
}

# Deployment using EBS
resource "kubernetes_deployment" "nginx" {
  metadata {
    name = "nginx"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }

      spec {
        container {
          image = "nginx:latest"
          name  = "nginx"

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nginx_pvc.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim.nginx_pvc,
    module.eks
  ]
}
