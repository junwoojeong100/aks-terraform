provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다 (azurerm 4.x 이후 필수 값).
  # azurerm 5.x 부터 Resource Provider 자동 등록 기본값이 "none" 입니다.
  # 필요한 RP 는 Lab 01 에서 az CLI 로 한 번만 등록합니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # 실습 정리를 쉽게 하기 위한 설정입니다. 운영에서는 기본값(true)을 권장합니다.
      prevent_deletion_if_contains_resources = false
    }
  }
}
