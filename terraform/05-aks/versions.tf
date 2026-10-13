terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    # azurerm 이 아직 지원하지 않는 AKS 신기능(Gateway API, 컨트롤 플레인 메트릭)은 AzAPI 로 켭니다.
    # (AWS 에서 aws 프로바이더가 따라오지 못하는 신규 API 를 awscc 프로바이더로 쓰는 것과 비슷합니다.)
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "05-aks.tfstate"
  }
}
