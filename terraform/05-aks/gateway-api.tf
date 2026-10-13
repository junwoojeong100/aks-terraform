# ---------------------------------------------------------------------------
# Enable Gateway API (the successor standard to Ingress)
#
# Background: community ingress-nginx maintenance ended in 2026-03, and Microsoft security patch support for the
#       AKS "application routing add-on (NGINX)" also ends in 2026-11. The successor is Gateway API,
#       and AKS offers two managed pieces:
#         1) Managed Gateway API CRDs        : AKS installs and upgrades CRDs such as Gateway/HTTPRoute
#         2) approuting-istio implementation : a sidecar-less Istio control plane turns Gateway resources into Envoy proxies
#
# azurerm_kubernetes_cluster in azurerm 5.9 does not expose this setting yet,
# so AzAPI applies it to the cluster as a "partial update".
# (Same approach as the official Microsoft Terraform sample 101-aks-application-routing-gateway-api)
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

  # Runs after control_plane_metrics so that PUTs against the same cluster don't overlap.
  depends_on = [azapi_update_resource.control_plane_metrics]
}
