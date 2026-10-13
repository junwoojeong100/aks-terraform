output "names" {
  description = "리소스별 이름 맵 (CAF 약어 + 결정적 해시 접미사)"
  value       = local.names
}

output "base" {
  description = "<workload>-<environment>-<region> 형태의 공통 접두 이름"
  value       = local.base
}

output "suffix" {
  description = "전역 고유 이름에 붙는 5자리 해시"
  value       = local.suffix
}
