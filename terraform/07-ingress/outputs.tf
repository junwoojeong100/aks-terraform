output "namespace" {
  description = "웹 앱 네임스페이스"
  value       = kubernetes_namespace_v1.web.metadata[0].name
}

output "app_image" {
  description = "배포된 이미지 (ACR 에 미리 import 되어 있어야 합니다)"
  value       = local.app_image
}

output "gateway_address_command" {
  description = "Gateway 에 할당된 로드밸런서 주소 조회 (할당까지 1~3분 소요)"
  value       = "kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}'"
}

output "curl_command" {
  description = "Gateway 주소로 요청 보내기 (internal_gateway=false 일 때)"
  value       = "curl -i http://$(kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')/"
}
