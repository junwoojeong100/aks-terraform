provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ---------------------------------------------------------------------------
# kubernetes provider → 05-aks 가 만든 클러스터에 접속
#   - 클러스터가 "이미 존재" 하는 상태에서 별도 스택으로 실행하므로, provider 설정이 apply 시점에 결정되는
#     리소스에 의존하지 않습니다 (클러스터 생성과 같은 스택에서 kubernetes provider 를 쓰면 흔히 겪는 문제 회피).
#   - 로컬 계정이 꺼져 있으므로 정적 인증서 대신 kubelogin 이 Azure CLI 로그인으로 토큰을 받아옵니다.
#     (EKS 의 `aws eks get-token` exec 플러그인과 같은 방식. server-id 는 AKS 의 Entra 서버 앱 ID 로 고정값입니다.)
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
