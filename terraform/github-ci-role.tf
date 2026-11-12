# Permissions for the IAM role GitHub Actions assumes through OIDC.
#
# You create the OIDC identity provider and the role BY HAND in the AWS console (see README,
# Part 1). Nothing secret exists anywhere: GitHub proves which workflow is running, AWS checks
# the role's trust policy and hands out 1-hour credentials.
# Terraform only grants the existing role two more things:
#   - in AWS:        read this cluster's address (aws eks update-kubeconfig)
#   - in Kubernetes: edit the "default" namespace, and nothing else

variable "github_ci_role" {
  description = "Name of the IAM role you created by hand for GitHub Actions (OIDC)"
  type        = string
  default     = "github-ci"
}

# Fails right away if you haven't created the role yet.
data "aws_iam_role" "github_ci" {
  name = var.github_ci_role
}

# AWS permission: only "describe this one cluster".
# (The role already has the ECR push policy you added by hand in Part 2.)
resource "aws_iam_role_policy" "github_ci" {
  name = "describe-${var.cluster_name}"
  role = data.aws_iam_role.github_ci.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = module.my_eks_cluster.cluster_arn
    }]
  })
}

# Kubernetes permission: IAM says WHO the caller is; this says WHAT it may do in the cluster.
resource "aws_eks_access_entry" "github_ci" {
  cluster_name  = module.my_eks_cluster.cluster_name
  principal_arn = data.aws_iam_role.github_ci.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_ci" {
  cluster_name  = module.my_eks_cluster.cluster_name
  principal_arn = data.aws_iam_role.github_ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.github_ci]
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.my_eks_cluster.cluster_name
}

output "github_ci_role_arn" {
  value = data.aws_iam_role.github_ci.arn
}

# The nodes pull the image from ECR with THEIR OWN role (the module attaches
# AmazonEC2ContainerRegistryReadOnly to it). GitHub's role is never used for pulling.
output "node_role_arn" {
  value = module.my_eks_cluster.eks_managed_node_groups["default"].iam_role_arn
}
