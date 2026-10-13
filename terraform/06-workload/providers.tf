provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ---------------------------------------------------------------------------
# kubernetes provider → connects to the cluster created by 05-aks
#   - This stack runs separately, after the cluster "already exists", so the provider configuration does not depend
#     on resources that are only known at apply time (avoids the common problem of using the kubernetes provider
#     in the same stack that creates the cluster).
#   - Local accounts are disabled, so instead of a static certificate, kubelogin gets a token from the Azure CLI login.
#     (Same approach as the `aws eks get-token` exec plugin on EKS. server-id is the fixed Entra server app ID of AKS.)
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}
