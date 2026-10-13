provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {}
}

# 06-workload 와 동일: kubelogin 으로 Entra ID 토큰을 받아 API 서버에 접속합니다.
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}
