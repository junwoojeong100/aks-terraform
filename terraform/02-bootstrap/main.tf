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
}

resource "azurerm_resource_group" "tfstate" {
  name     = module.naming.names.rg_tfstate
  location = var.location
  tags     = local.tags
}

# S3 버킷 + (DynamoDB 락 테이블) 에 해당합니다.
# Azure Blob 백엔드는 blob lease 로 state 잠금을 제공하므로 별도의 락 테이블이 필요 없습니다.
resource "azurerm_storage_account" "tfstate" {
  name                = module.naming.names.st_tfstate
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS" # 가용 영역 3곳에 동기 복제 (S3 의 기본 다중 AZ 내구성과 유사)

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false # S3 Block Public Access
  shared_access_key_enabled       = false # 계정 키 사용 금지 → Entra ID(RBAC) 인증만 허용
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true # S3 Versioning: 잘못된 state 로 되돌릴 수 있습니다.

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# 현재 로그인한 사용자(또는 CI 의 서비스 주체)에게 state 읽기/쓰기 권한 부여.
# IAM 정책(s3:GetObject/PutObject) 대신 Azure RBAC 역할 할당을 사용합니다.
resource "azurerm_role_assignment" "state_contributor" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
