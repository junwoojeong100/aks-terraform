# Run: terraform -chdir=terraform/modules/naming test
# A pure logic test that works without a provider (terraform test is the testing framework built into Terraform).

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
    error_message = "The AKS name must be aks-<workload>-<env>-<region>."
  }

  assert {
    condition     = output.names.rg_aks == "rg-aksdemo-dev-krc-aks"
    error_message = "A resource group name must be rg-<base>-<purpose>."
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
    error_message = "A Storage Account name must be 3–24 lowercase letters or digits."
  }

  assert {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", output.names.key_vault))
    error_message = "A Key Vault name must be 3–24 characters and start with a letter."
  }

  assert {
    condition     = can(regex("^[a-z0-9]{5,50}$", output.names.acr))
    error_message = "An ACR name must be 5–50 lowercase letters or digits."
  }

  assert {
    condition     = length(output.names.grafana) <= 23
    error_message = "A Managed Grafana name must be 23 characters or fewer."
  }
}

run "unknown_region_falls_back_to_prefix" {
  command = plan

  variables {
    location = "brazilsouth"
  }

  assert {
    condition     = output.base == "aksdemo-dev-braz"
    error_message = "A region that is not in the mapping must use its first 4 characters as the code."
  }
}

run "suffix_has_five_characters" {
  command = plan

  variables {
    subscription_id = "11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = length(output.suffix) == 5
    error_message = "The hash suffix must be 5 characters."
  }
}

run "rejects_too_long_workload" {
  command = plan

  variables {
    workload = "waytoolongworkload"
  }

  expect_failures = [var.workload]
}
