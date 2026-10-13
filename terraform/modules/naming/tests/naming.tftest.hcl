# 실행: terraform -chdir=terraform/modules/naming test
# Provider 없이 동작하는 순수 로직 테스트입니다 (terraform test 는 Terraform 에 내장된 테스트 프레임워크).

variables {
  workload        = "aksdemo"
  environment     = "dev"
  location        = "koreacentral"
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "defaults_follow_naming_convention" {
  command = plan

  assert {
    condition     = output.names.aks == "aks-aksdemo-dev-krc"
    error_message = "AKS 이름은 aks-<workload>-<env>-<region> 이어야 합니다."
  }

  assert {
    condition     = output.names.rg_aks == "rg-aksdemo-dev-krc-aks"
    error_message = "리소스 그룹 이름은 rg-<base>-<용도> 이어야 합니다."
  }
}

run "globally_unique_names_fit_service_limits" {
  command = plan

  variables {
    workload    = "aksdemo8"
    environment = "prod"
  }

  assert {
    condition     = can(regex("^[a-z0-9]{3,24}$", output.names.st_tfstate))
    error_message = "Storage Account 이름은 3~24자 소문자/숫자여야 합니다."
  }

  assert {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", output.names.key_vault))
    error_message = "Key Vault 이름은 3~24자이며 영문자로 시작해야 합니다."
  }

  assert {
    condition     = can(regex("^[a-z0-9]{5,50}$", output.names.acr))
    error_message = "ACR 이름은 5~50자 소문자/숫자여야 합니다."
  }

  assert {
    condition     = length(output.names.grafana) <= 23
    error_message = "Managed Grafana 이름은 23자 이하여야 합니다."
  }
}

run "unknown_region_falls_back_to_prefix" {
  command = plan

  variables {
    location = "brazilsouth"
  }

  assert {
    condition     = output.base == "aksdemo-dev-braz"
    error_message = "매핑에 없는 리전은 앞 4글자를 코드로 사용해야 합니다."
  }
}

run "suffix_has_five_characters" {
  command = plan

  variables {
    subscription_id = "11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = length(output.suffix) == 5
    error_message = "해시 접미사는 5자리여야 합니다."
  }
}

run "rejects_too_long_workload" {
  command = plan

  variables {
    workload = "waytoolongworkload"
  }

  expect_failures = [var.workload]
}
