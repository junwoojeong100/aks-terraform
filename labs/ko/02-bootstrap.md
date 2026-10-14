<!-- lang-switch -->
[English](../02-bootstrap.md) | **한국어**
<!-- /lang-switch -->

# Lab 02. Terraform 원격 State: S3 + DynamoDB ↔ Blob Storage

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 20분 | 거의 없음 | `terraform/02-bootstrap`, `terraform/modules/naming` | [01. 사전 준비](01-prerequisites.md) |

## 이번 실습에서 만드는 것

모든 스택이 공유할 **원격 state 저장소**(Storage Account + Container)와, 모든 스택이 같은 이름 규칙을 쓰게 해 주는 **공통 모듈(`naming`)** 입니다.

![Terraform 스택 계층과 실행 순서](diagrams/stack-layers.svg)

state 저장소의 구조는 다음과 같습니다.

```text
 rg-aksdemo-dev-krc-tfstate
 └── sttfstateaksdemo<hash>  (Storage Account, ZRS, 키 인증 비활성화)
     └── container "tfstate"
         ├── 03-network.tfstate     ← Lab 03
         ├── 04-platform.tfstate    ← Lab 04
         ├── 05-aks.tfstate         ← Lab 05
         └── ...
```

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| S3 bucket | Storage Account + **Blob container** | Storage Account 이름이 **전역 고유**(소문자·숫자 3–24자). |
| DynamoDB lock table | (불필요) | azurerm backend 가 **blob lease** 로 잠금을 처리합니다. |
| S3 Versioning | `blob_properties.versioning_enabled` | 잘못 덮어쓴 state 를 이전 버전으로 복구. |
| Block Public Access | `allow_nested_items_to_be_public = false` | 컨테이너 공개 접근 차단. |
| IAM 정책 (s3:GetObject/PutObject) | RBAC **Storage Blob Data Contributor** | 데이터 평면 역할이 따로 있습니다. `Contributor`(관리 평면)만으로는 blob 을 읽고 쓸 수 없습니다. |
| 액세스 키/자격 증명 | `shared_access_key_enabled = false` + `use_azuread_auth = true` | 계정 키를 아예 끄고 Entra ID 인증만 허용합니다. |

> [!TIP]
> **상태를 스택별로 나누는 이유**: 네트워크(거의 안 바뀜) → 플랫폼 서비스 → 클러스터 → 워크로드는 변경 주기와 권한 주체가 다릅니다. state 를 나누면 변경 영향 범위(blast radius)가 줄고, 실수로 VNet 을 건드리는 일이 줄어듭니다.
> 스택 사이는 `terraform_remote_state` 대신 **이름 규칙 + data source** 로 연결합니다(상태 파일 접근 권한을 공유할 필요가 없고, 순환 의존이 생기지 않습니다).

## 공통 모듈: `modules/naming`

Azure 는 **리소스 이름 규칙**(Cloud Adoption Framework 약어)과 **전역 고유 이름** 문제가 큽니다(ACR, Key Vault, Storage). 이 모듈은 `구독 ID + workload + environment` 로 5자리 해시를 만들어, 어느 스택에서 호출해도 **같은 이름을 재현**합니다.

<!-- tf:include path="terraform/modules/naming/variables.tf" -->
```hcl title="terraform/modules/naming/variables.tf"
variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits). Example: aksdemo"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.workload))
    error_message = "workload must be 3–8 lowercase letters or digits (due to Key Vault and Storage name length limits)."
  }
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of dev, test, or prod."
  }
}

variable "location" {
  description = "Azure region name (e.g., koreacentral)"
  type        = string
}

variable "subscription_id" {
  description = "Subscription ID. Used to compute the hash suffix appended to globally unique names (ACR, Key Vault, Storage)."
  type        = string
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/modules/naming/main.tf" -->
```hcl title="terraform/modules/naming/main.tf"
locals {
  # Follows the Cloud Adoption Framework (CAF) abbreviations, but shortens regions to short codes.
  region_codes = {
    koreacentral       = "krc"
    koreasouth         = "krs"
    japaneast          = "jpe"
    japanwest          = "jpw"
    eastasia           = "eas"
    southeastasia      = "sea"
    australiaeast      = "aue"
    eastus             = "eus"
    eastus2            = "eus2"
    westus2            = "wus2"
    westus3            = "wus3"
    centralus          = "cus"
    northeurope        = "neu"
    westeurope         = "weu"
    uksouth            = "uks"
    swedencentral      = "sec"
    germanywestcentral = "gwc"
  }

  region_code = lookup(local.region_codes, var.location, substr(var.location, 0, 4))
  base        = "${var.workload}-${var.environment}-${local.region_code}"
  flat        = "${var.workload}${var.environment}${local.region_code}"

  # A hash determined by subscription + workload. Every stack reproduces the same value, so
  # they can find each other's "globally unique names" (ACR, Key Vault, Storage) without remote state.
  suffix = substr(sha256("${var.subscription_id}/${var.workload}/${var.environment}"), 0, 5)

  names = {
    # Resource groups (separated by lifecycle)
    rg_tfstate   = "rg-${local.base}-tfstate"
    rg_network   = "rg-${local.base}-network"
    rg_platform  = "rg-${local.base}-platform"
    rg_aks       = "rg-${local.base}-aks"
    rg_aks_nodes = "rg-${local.base}-aks-nodes"
    rg_workload  = "rg-${local.base}-workload"

    # Terraform state (3–24 characters, lowercase letters + digits)
    st_tfstate = "sttfstate${var.workload}${local.suffix}"

    # Network
    vnet                  = "vnet-${local.base}"
    snet_aks_nodes        = "snet-aks-nodes"
    snet_aks_apiserver    = "snet-aks-apiserver"
    snet_ingress          = "snet-ingress"
    snet_private_endpoint = "snet-private-endpoints"
    nsg_aks_nodes         = "nsg-${local.base}-aks-nodes"
    nsg_ingress           = "nsg-${local.base}-ingress"
    nsg_private_endpoint  = "nsg-${local.base}-private-endpoints"
    nat_gateway           = "ng-${local.base}"
    pip_nat_gateway       = "pip-ng-${local.base}"

    # Platform services
    log_analytics          = "log-${local.base}"
    monitor_workspace      = "amw-${local.base}"
    grafana                = "amg-${local.base}"
    acr                    = "acr${local.flat}${local.suffix}"
    key_vault              = "kv-${var.workload}-${var.environment}-${local.suffix}"
    id_aks_cluster         = "id-aks-${local.base}-cluster"
    id_aks_kubelet         = "id-aks-${local.base}-kubelet"
    dce_prometheus         = "dce-${local.base}-prometheus"
    dcr_prometheus         = "dcr-${local.base}-prometheus"
    dcr_container_insights = "dcr-${local.base}-container-insights"

    # AKS
    aks = "aks-${local.base}"

    # AKS Automatic (Lab 10)
    rg_automatic     = "rg-${local.base}-automatic"
    aks_automatic    = "aksa-${local.base}"
    vnet_automatic   = "vnet-${local.base}-automatic"
    id_aks_automatic = "id-aks-${local.base}-automatic"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/modules/naming/outputs.tf" -->
```hcl title="terraform/modules/naming/outputs.tf"
output "names" {
  description = "Map of names per resource (CAF abbreviations + deterministic hash suffix)"
  value       = local.names
}

output "base" {
  description = "Common name prefix in the form <workload>-<environment>-<region>"
  value       = local.base
}

output "suffix" {
  description = "5-character hash appended to globally unique names"
  value       = local.suffix
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/modules/naming/versions.tf" -->
```hcl title="terraform/modules/naming/versions.tf"
terraform {
  required_version = "~> 1.16"
}
```
<!-- /tf:include -->

`terraform test` 는 Terraform 내장 테스트 프레임워크입니다. Provider 가 없는 순수 로직이라 바로 실행됩니다.

<!-- tf:include path="terraform/modules/naming/tests/naming.tftest.hcl" -->
```hcl title="terraform/modules/naming/tests/naming.tftest.hcl"
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
```
<!-- /tf:include -->

```bash
terraform -chdir=terraform/modules/naming init -backend=false
terraform -chdir=terraform/modules/naming test        # 5 passed
```

## 부트스트랩 스택 코드

**`versions.tf`** — 스택의 `terraform {}` 설정입니다. 모든 스택에 하나씩 있고, 세 가지를 담습니다.

- `required_version`: 이 스택을 실행할 수 있는 Terraform CLI 버전입니다(`~> 1.16` = 1.16 이상 2.0 미만).
- `required_providers`: 각 provider 의 출처와 허용하는 버전 범위입니다(`~> 5.9` = 5.9 이상 6 미만). `terraform init` 이 실제로 고른 정확한 버전과 체크섬은 `.terraform.lock.hcl` 에 기록되며, 이 저장소는 그 파일을 커밋해 모두가 같은 provider 빌드를 쓰게 합니다.
- `backend`: state 를 어디에 저장할지 정합니다. 블록에는 state `key` 와 Entra ID 인증만 고정하고, 스토리지 계정과 컨테이너는 `backend.hcl`(3단계)에서 받습니다. 이 스택만 예외로, state 저장소를 스스로 만들기 때문에 마지막의 블록을 주석 처리해 두었다가 아래 *4단계*에서만 사용합니다.

`provider` 블록 자체는 `providers.tf` 에 있습니다. AWS 경험자라면 AWS 프로젝트의 `required_providers`, `backend "s3"` 와 같은 역할입니다.

<!-- tf:include path="terraform/02-bootstrap/versions.tf" -->
```hcl title="terraform/02-bootstrap/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # The bootstrap stack starts with local state (it creates the state storage itself: a "chicken-and-egg" problem).
  # In the last step of Lab 02, uncomment the block below and migrate state with
  # `terraform init -migrate-state -backend-config=../backend.hcl`.
  #
  # backend "azurerm" {
  #   use_azuread_auth = true
  #   key              = "02-bootstrap.tfstate"
  # }
}
```
<!-- /tf:include -->

**`providers.tf`** — azurerm 5.x 는 Resource Provider 를 자동 등록하지 않습니다(`none`).

<!-- tf:include path="terraform/02-bootstrap/providers.tf" -->
```hcl title="terraform/02-bootstrap/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable (required since azurerm 4.x).
  # Since azurerm 5.x, automatic Resource Provider registration defaults to "none".
  # Register the required RPs once with the az CLI in Lab 01.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # This setting makes lab cleanup easier. In production, keep the default (true).
      prevent_deletion_if_contains_resources = false
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/variables.tf" -->
```hcl title="terraform/02-bootstrap/variables.tf"
variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
```
<!-- /tf:include -->

**`main.tf`** — 스토리지 계정은 ZRS(영역 중복), 키 인증 비활성화, 버전 관리, 소프트 삭제를 켭니다.

<!-- tf:include path="terraform/02-bootstrap/main.tf" -->
```hcl title="terraform/02-bootstrap/main.tf"
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

# Equivalent to an S3 bucket + (DynamoDB lock table).
# The Azure Blob backend provides state locking through blob leases, so no separate lock table is needed.
resource "azurerm_storage_account" "tfstate" {
  name                = module.naming.names.st_tfstate
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS" # Synchronous replication across 3 availability zones (like S3's default multi-AZ durability)

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false # S3 Block Public Access
  shared_access_key_enabled       = false # Disable account keys → allow Entra ID (RBAC) authentication only
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true # S3 Versioning: lets you restore a previous version after a bad state overwrite.

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

# Grant the signed-in user (or the CI service principal) read/write access to state.
# Uses an Azure RBAC role assignment instead of an IAM policy (s3:GetObject/PutObject).
resource "azurerm_role_assignment" "state_contributor" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/outputs.tf" -->
```hcl title="terraform/02-bootstrap/outputs.tf"
output "backend_hcl" {
  description = "Save with `terraform output -raw backend_hcl > ../backend.hcl` and use it as the partial backend configuration of the other stacks."
  value       = <<-EOT
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}

output "tfstate_storage_account_name" {
  description = "Name of the storage account that holds state"
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_resource_group_name" {
  description = "Name of the resource group for state storage"
  value       = azurerm_resource_group.tfstate.name
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/tests/plan.tftest.hcl" -->
```hcl title="terraform/02-bootstrap/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/02-bootstrap test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_storage_account.tfstate.shared_access_key_enabled == false
    error_message = "The state storage account must disable account-key authentication (Entra ID authentication only)."
  }

  assert {
    condition     = azurerm_storage_account.tfstate.blob_properties[0].versioning_enabled
    error_message = "Blob versioning must be enabled so that state can be recovered."
  }
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 환경 변수 확인

```bash
source env.sh 2>/dev/null || true   # Lab 01 에서 저장했다면
echo $ARM_SUBSCRIPTION_ID $TF_VAR_workload $TF_VAR_environment $TF_VAR_location
```

### 2단계. 계획과 적용

처음에는 state 저장소가 없으므로 **로컬 state** 로 실행합니다.

```bash
cd terraform/02-bootstrap
terraform init
terraform plan -out tfplan        # 4개 리소스: 리소스 그룹, Storage Account, Container, 역할 할당
terraform apply tfplan
```

> [!NOTE]
> `-out tfplan` 으로 저장한 계획을 그대로 `apply` 하면 "리뷰한 변경"만 적용됩니다(운영 파이프라인의 기본 패턴).

### 3단계. 다른 스택이 쓸 backend 설정 저장

`backend.hcl` 은 partial backend configuration 입니다. 스토리지 계정 이름을 코드에 하드코딩하지 않기 위해 `-backend-config` 로 주입합니다.

```bash
terraform output -raw backend_hcl > ../backend.hcl
cat ../backend.hcl
```

```hcl
storage_account_name = "sttfstateaksdemo1a2b3"
container_name       = "tfstate"
use_azuread_auth     = true
```

> [!IMPORTANT]
> `backend.hcl` 에는 비밀이 없지만(키 인증을 쓰지 않음) 환경마다 달라지므로 저장소에는 커밋하지 않습니다(`terraform/.gitignore` 에 포함).

### 4단계. (선택) 부트스트랩 스택의 state 도 원격으로 이전

1. `terraform/02-bootstrap/versions.tf` 의 `backend "azurerm"` 블록 주석을 해제합니다.
2. 역할 할당이 전파되는 데 1–5분 걸릴 수 있습니다. 아래 명령이 `403` 으로 실패하면 잠시 후 다시 실행하세요.

```bash
terraform init -migrate-state -backend-config=../backend.hcl
# "Do you want to copy existing state to the new backend?" → yes
```

> [!NOTE]
> 이 수정은 내 환경에만 해당하므로 커밋하지 마세요. 저장소는 누구나 로컬 state 로 Lab 02 를 시작할 수 있도록 이 블록을 주석 처리한 채로 두며(이 저장소의 CI 는 블록이 켜져 있으면 실패합니다), Lab 11 의 2단계에서 다시 주석 처리합니다.

### 5단계. 검증

```bash
ST=$(terraform output -raw tfstate_storage_account_name)

# Entra ID 로그인으로 컨테이너/블롭 조회 (계정 키를 쓰지 않음)
az storage blob list --account-name "$ST" --container-name tfstate --auth-mode login -o table

# 키 인증이 꺼져 있는지 확인 → false 여야 합니다
az storage account show -n "$ST" --query allowSharedKeyAccess -o tsv
```

**잠금 동작 확인**: 터미널 두 개에서 동시에 `terraform plan` 을 실행하면 두 번째가 `Error acquiring the state lock`(blob lease) 로 대기/실패합니다. 이 때 `-lock-timeout=60s` 를 주면 잠금이 풀릴 때까지 기다립니다.

## 이후 모든 스택에서 쓰는 init 패턴

03–10 스택은 `versions.tf` 의 `backend "azurerm"` 블록이 이미 켜져 있고, 그 스택의 state `key` 만 고정합니다. 스토리지 계정과 컨테이너는 `-backend-config` 로 `backend.hcl` 에서 받습니다.

```bash
terraform init -backend-config=../backend.hcl
```

### 자동 검증 스크립트

5단계의 수동 확인(키 인증 차단, 버전 관리, 컨테이너, state 파일)을 한 번에 실행합니다. **읽기 전용**이며 `✓ 통과 / ✗ 실패 / ! 경고` 요약과 종료 코드(실패가 있으면 1)를 돌려줍니다.

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 02-bootstrap
```

<!-- tf:include path="scripts/verify/02-bootstrap.sh" -->
```bash title="scripts/verify/02-bootstrap.sh"
#!/usr/bin/env bash
# Lab 02 verification: checks that the Terraform state storage (Storage Account + Blob container)
# was created securely (read-only).
#   AWS comparison: S3 bucket (Versioning, Block Public Access) + DynamoDB lock table
#   → Azure covers both with one Blob container (locking uses a blob lease).
# Usage: scripts/verify.sh 02-bootstrap
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg sa acct blobsvc containers keys
  rg="$(tf_out 02-bootstrap tfstate_resource_group_name)"
  sa="$(tf_out 02-bootstrap tfstate_storage_account_name)"

  section "02-bootstrap · state storage (${sa:-?})"
  if [ -z "$sa" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 02-bootstrap?"
    return
  fi

  acct="$(azj storage account show -g "$rg" -n "$sa")"
  if [ -z "$acct" ]; then
    fail "Storage account not found: $sa"
    return
  fi

  expect_eq "Replication (synchronous across 3 availability zones)" "$(jv "$acct" .sku.name)" "Standard_ZRS"
  expect_eq "Public blob access allowed (S3 Block Public Access)" "$(jv "$acct" .allowBlobPublicAccess)" "false"
  expect_eq "Account key (Shared Key) auth allowed → Entra ID only" "$(jv "$acct" .allowSharedKeyAccess)" "false"
  expect_eq "Minimum TLS version" "$(jv "$acct" .minimumTlsVersion)" "TLS1_2"
  expect_eq "HTTPS only" "$(jv "$acct" .enableHttpsTrafficOnly)" "true"

  blobsvc="$(azj storage account blob-service-properties show -g "$rg" --account-name "$sa")"
  expect_eq "Blob versioning (S3 Versioning)" "$(jv "$blobsvc" .isVersioningEnabled)" "true"
  expect_eq "Blob soft delete" "$(jv "$blobsvc" .deleteRetentionPolicy.enabled)" "true"

  # Listing containers/blobs is a data-plane call, so it uses --auth-mode login (Entra ID).
  containers="$(azj storage container list --account-name "$sa" --auth-mode login)"
  jq_ok "Container 'tfstate' exists (private)" "$containers" '[.[] | select(.name == "tfstate" and .properties.publicAccess == null)] | length == 1'

  keys="$(az storage blob list --account-name "$sa" -c tfstate --auth-mode login --query '[].name' -o tsv 2>/dev/null | tr '\n' ' ')"
  if [ -n "$keys" ]; then
    pass "State files: $keys"
  else
    warn "No state file yet (normal before the state migration in the last step of Lab 02)"
  fi
}

# You can also run it directly (scripts/verify/02-bootstrap.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `AuthorizationPermissionMismatch` (init 시 403) | 역할 할당 전파 지연. 1–5분 후 재시도. `Storage Blob Data Contributor` 가 **컨테이너/계정** 범위에 있는지 확인. |
| `StorageAccountAlreadyTaken` | 이름이 전역 중복. `TF_VAR_workload` 를 바꾸면 해시가 달라집니다. |
| `subscription_id is required` | `ARM_SUBSCRIPTION_ID` 환경 변수 미설정(Lab 01 의 5단계). |
| `Error: Failed to get existing workspaces` | 현재 사용자에게 데이터 평면 역할이 없거나 `use_azuread_auth` 가 빠짐. |

다음 → [Lab 03. 네트워크: VNet · NSG · NAT Gateway · Private DNS](03-network.md)
