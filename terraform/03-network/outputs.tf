output "resource_group_name" {
  description = "네트워크 리소스 그룹"
  value       = azurerm_resource_group.network.name
}

output "vnet_name" {
  description = "VNet 이름 (이후 스택에서 data source 로 조회)"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "서브넷 ID 맵"
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    aks_apiserver     = azurerm_subnet.aks_apiserver.id
    ingress           = azurerm_subnet.ingress.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "nat_gateway_public_ip" {
  description = "클러스터 아웃바운드가 나가는 고정 공인 IP (외부 서비스 방화벽 허용 목록에 등록할 값)"
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Private Endpoint 용 Private DNS Zone"
  value       = [for zone in azurerm_private_dns_zone.this : zone.name]
}
