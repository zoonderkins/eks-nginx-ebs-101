# Add data source to get AWS account ID
data "aws_caller_identity" "current" {}

# Add a delay to ensure EKS is fully ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks wait cluster-active --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile}
      sleep 60
    EOT
  }
}

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

# Add a check for EBS CSI driver
resource "null_resource" "verify_ebs_csi_driver" {
  depends_on = [module.eks, null_resource.wait_for_cluster]

  provisioner "local-exec" {
    command     = <<-EOT
      # Check if the EBS CSI driver addon is active
      aws eks describe-addon --cluster-name ${var.cluster_name} --addon-name aws-ebs-csi-driver --region ${var.region} --profile ${var.aws_profile}
      
      # Generate a temporary kubeconfig file
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --kubeconfig /tmp/kubeconfig-${var.cluster_name}
      
      # Use the generated kubeconfig to check for EBS CSI driver pods
      kubectl --kubeconfig /tmp/kubeconfig-${var.cluster_name} get pods -n kube-system | grep ebs-csi || echo "EBS CSI driver pods not found yet, but continuing..."
      
      # Clean up the temporary kubeconfig
      rm -f /tmp/kubeconfig-${var.cluster_name}
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# Add a resource to ensure EBS CSI driver is ready
resource "null_resource" "ensure_ebs_csi_driver_ready" {
  depends_on = [module.eks, null_resource.wait_for_cluster, null_resource.verify_ebs_csi_driver]

  provisioner "local-exec" {
    command     = <<-EOT
      # Generate a temporary kubeconfig file
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --kubeconfig /tmp/kubeconfig-ensure-${var.cluster_name}
      
      # Wait for EBS CSI driver pods to be running
      echo "Waiting for EBS CSI driver pods to be running..."
      for i in {1..30}; do
        if kubectl --kubeconfig /tmp/kubeconfig-ensure-${var.cluster_name} get pods -n kube-system | grep ebs-csi | grep -q Running; then
          echo "EBS CSI driver pods are running"
          break
        fi
        if [ $i -eq 30 ]; then
          echo "Timed out waiting for EBS CSI driver pods to be running, but continuing..."
        fi
        echo "Waiting for EBS CSI driver pods to be running (attempt $i/30)..."
        sleep 10
      done
      
      # Clean up the temporary kubeconfig
      rm -f /tmp/kubeconfig-ensure-${var.cluster_name}
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

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
    module.eks,
    module.eks.eks_managed_node_groups,
    null_resource.wait_for_cluster,
    null_resource.verify_ebs_csi_driver,
    null_resource.ensure_ebs_csi_driver_ready
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
    kubernetes_storage_class.ebs_sc,
    null_resource.wait_for_cluster,
    null_resource.ensure_ebs_csi_driver_ready
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

# Debug output
resource "null_resource" "debug_info" {
  depends_on = [
    module.eks,
    null_resource.wait_for_cluster,
    null_resource.verify_ebs_csi_driver
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      echo "==== EKS Cluster Info ===="
      aws eks describe-cluster --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --query 'cluster.status'
      
      echo "==== EKS Node Groups ===="
      aws eks list-nodegroups --cluster-name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile}
      
      echo "==== EKS Addons ===="
      aws eks list-addons --cluster-name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile}
      
      # Generate a temporary kubeconfig file
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --kubeconfig /tmp/kubeconfig-debug-${var.cluster_name}
      
      echo "==== Kubernetes Storage Classes ===="
      kubectl --kubeconfig /tmp/kubeconfig-debug-${var.cluster_name} get sc
      
      echo "==== Kubernetes Nodes ===="
      kubectl --kubeconfig /tmp/kubeconfig-debug-${var.cluster_name} get nodes
      
      echo "==== Kubernetes Pods ===="
      kubectl --kubeconfig /tmp/kubeconfig-debug-${var.cluster_name} get pods --all-namespaces | grep -E 'ebs|csi|storage' || echo "No storage-related pods found"
      
      # Clean up the temporary kubeconfig
      rm -f /tmp/kubeconfig-debug-${var.cluster_name}
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}
