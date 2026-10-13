# ---------------------------------------------------------------------------
# Gateway API (Ingress 의 후속 표준) 활성화
#
# 배경: 커뮤니티 ingress-nginx 는 2026-03 에 유지보수가 종료되었고, AKS 의 "application routing add-on(NGINX)" 에 대한
#       Microsoft 보안 패치 지원도 2026-11 에 끝납니다. 후속은 Gateway API 이며, AKS 는 두 가지를 관리형으로 제공합니다.
#         1) Managed Gateway API CRDs  : Gateway/HTTPRoute 등 CRD 를 AKS 가 설치·업그레이드
#         2) approuting-istio 구현체   : 사이드카 없는 Istio 컨트롤 플레인이 Gateway 리소스를 Envoy 프록시로 만들어 줌
#
# azurerm 5.9 의 azurerm_kubernetes_cluster 는 아직 이 설정을 노출하지 않으므로 AzAPI 로 클러스터에 "부분 업데이트" 합니다.
# (Microsoft 공식 Terraform 샘플 101-aks-application-routing-gateway-api 와 같은 방식)
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "gateway_api" {
  count = var.enable_gateway_api ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  # 같은 클러스터에 대한 PUT 이 겹치지 않도록 control_plane_metrics 뒤에 순서대로 실행합니다.
  depends_on = [azapi_update_resource.control_plane_metrics]
}
