terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # 부트스트랩 스택은 처음에는 로컬 state 를 사용합니다 (state 저장소를 만드는 스택이므로 "닭과 달걀" 문제).
  # Lab 02 마지막 단계에서 아래 주석을 해제하고 `terraform init -migrate-state -backend-config=../backend.hcl` 로 state 를 이전합니다.
  #
  # backend "azurerm" {
  #   use_azuread_auth = true
  #   key              = "02-bootstrap.tfstate"
  # }
}
