provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# AzAPI 도 ARM_SUBSCRIPTION_ID 와 Azure CLI 로그인 정보를 그대로 사용합니다.
provider "azapi" {}
