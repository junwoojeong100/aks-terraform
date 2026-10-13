data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed_by  = "terraform"
      lab         = "aks-terraform-guide"
    },
    var.tags,
  )

  # Key Vault IP 규칙은 /31, /32 접두사를 받지 않으므로 단일 IP 로 변환합니다.
  key_vault_ip_rules = [for cidr in var.allowed_ip_ranges : replace(cidr, "/32", "")]
}

# ---------------------------------------------------------------------------
# 03-network 스택이 만든 리소스를 "이름 규칙"으로 조회합니다.
# AWS 의 `data "aws_vpc"` + 태그 조회와 같은 방식이며, remote state 의존성이 없습니다.
# ---------------------------------------------------------------------------
data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_subnet" "private_endpoints" {
  name                 = module.naming.names.snet_private_endpoint
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = module.naming.names.rg_network
}

# ---------------------------------------------------------------------------
# 플랫폼(공용 서비스) 리소스 그룹
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "platform" {
  name     = module.naming.names.rg_platform
  location = var.location
  tags     = local.tags
}
