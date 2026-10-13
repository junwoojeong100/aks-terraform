# ---------------------------------------------------------------------------
# Gateway API 로 외부 트래픽 받기  (AWS Load Balancer Controller 의 Ingress/ALB 에 해당)
#
#   GatewayClass(approuting-istio) : AKS 가 설치 (05-aks 의 azapi 단계에서 활성화)
#   Gateway                        : 포트/프로토콜/로드밸런서 노출 방식 → 플랫폼 팀 관점 (ALB + Listener)
#   HTTPRoute                      : 호스트/경로 → 서비스 매핑          → 앱 팀 관점   (Listener rule + Target group)
#
# Gateway 를 적용하면 같은 네임스페이스에 Envoy 프록시 Deployment, LoadBalancer Service, HPA, PDB 가 자동 생성됩니다.
# ---------------------------------------------------------------------------
locals {
  # internal_gateway = true 일 때만 Azure 내부 로드밸런서(사설 IP)를 쓰도록 Service annotation 을 전달합니다.
  # (조건에 따라 키 자체가 없어야 하므로 tomap + merge 패턴을 사용합니다.)
  gateway_infrastructure = var.internal_gateway ? tomap({
    infrastructure = {
      annotations = {
        "service.beta.kubernetes.io/azure-load-balancer-internal"        = "true"
        "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" = var.ingress_subnet_name
      }
    }
  }) : tomap({})

  gateway_spec = merge(
    {
      gatewayClassName = "approuting-istio"

      listeners = [
        {
          name     = "http"
          port     = 80
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = {
              from = "Same"
            }
          }
        }
      ]
    },
    local.gateway_infrastructure,
  )
}

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"

    metadata = {
      name      = "web-gateway"
      namespace = kubernetes_namespace_v1.web.metadata[0].name
    }

    spec = local.gateway_spec
  }
}

resource "kubernetes_manifest" "http_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"

    metadata = {
      name      = local.app_name
      namespace = kubernetes_namespace_v1.web.metadata[0].name
    }

    spec = {
      parentRefs = [
        {
          name = "web-gateway"
        }
      ]

      rules = [
        {
          matches = [
            {
              path = {
                type  = "PathPrefix"
                value = "/"
              }
            }
          ]

          backendRefs = [
            {
              name = kubernetes_service_v1.app.metadata[0].name
              port = 80
            }
          ]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.gateway]
}
