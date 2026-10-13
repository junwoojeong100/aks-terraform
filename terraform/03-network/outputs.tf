output "resource_group_name" {
  description = "Network resource group"
  value       = azurerm_resource_group.network.name
}

output "vnet_name" {
  description = "VNet name (looked up with a data source in later stacks)"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Map of subnet IDs"
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    aks_apiserver     = azurerm_subnet.aks_apiserver.id
    ingress           = azurerm_subnet.ingress.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "nat_gateway_public_ip" {
  description = "Static public IP for cluster outbound traffic (the value to add to external services' firewall allow lists)"
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Private DNS Zones for Private Endpoints"
  value       = [for zone in azurerm_private_dns_zone.this : zone.name]
}
