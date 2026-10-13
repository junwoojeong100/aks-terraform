output "namespace" {
  description = "Web app namespace"
  value       = kubernetes_namespace_v1.web.metadata[0].name
}

output "app_image" {
  description = "Deployed image (must be imported into ACR beforehand)"
  value       = local.app_image
}

output "gateway_address_command" {
  description = "Look up the load balancer address assigned to the Gateway (assignment takes 1–3 min)"
  value       = "kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}'"
}

output "curl_command" {
  description = "Send a request to the Gateway address (when internal_gateway=false)"
  value       = "curl -i http://$(kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')/"
}
