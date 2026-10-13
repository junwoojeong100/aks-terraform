# ---------------------------------------------------------------------------
# Receiving external traffic with the Gateway API  (equivalent to Ingress/ALB in the AWS Load Balancer Controller)
#
#   GatewayClass(approuting-istio) : installed by AKS (enabled in the azapi step of 05-aks)
#   Gateway                        : port/protocol/load balancer exposure → platform team view (ALB + Listener)
#   HTTPRoute                      : host/path → service mapping          → app team view      (Listener rule + Target group)
#
# Applying a Gateway auto-creates an Envoy proxy Deployment, LoadBalancer Service, HPA, and PDB in the same namespace.
# ---------------------------------------------------------------------------
locals {
  # Pass Service annotations for an Azure internal load balancer (private IP) only when internal_gateway = true.
  # (The key must be absent entirely depending on the condition, so this uses the tomap + merge pattern.)
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
