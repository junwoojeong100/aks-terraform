provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # 이름이 같은 soft-deleted Key Vault 가 있으면 새로 만들지 않고 복구합니다.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }

    log_analytics_workspace {
      # 실습 후 같은 이름으로 다시 만들 수 있도록 destroy 시 영구 삭제합니다.
      permanently_delete_on_destroy = true
    }
  }
}
