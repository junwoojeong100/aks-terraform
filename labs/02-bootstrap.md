# Lab 02. Terraform 원격 State: S3 + DynamoDB ↔ Blob Storage

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 20분 | 거의 없음 | `terraform/02-bootstrap`, `terraform/modules/naming` | [01. 사전 준비](01-prerequisites.md) |

## 이번 실습에서 만드는 것

모든 스택이 공유할 **원격 state 저장소**(Storage Account + Container)와, 모든 스택이 같은 이름 규칙을 쓰게 해 주는 **공통 모듈(`naming`)** 입니다.

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
  description = "워크로드 이름 (소문자/숫자 3~8자). 예: aksdemo"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.workload))
    error_message = "workload는 소문자/숫자 3~8자여야 합니다 (Key Vault·Storage 이름 길이 제한 때문)."
  }
}

variable "environment" {
  description = "환경 구분 (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment는 dev, test, prod 중 하나여야 합니다."
  }
}

variable "location" {
  description = "Azure 리전 이름 (예: koreacentral)"
  type        = string
}

variable "subscription_id" {
  description = "구독 ID. 전역 고유 이름(ACR, Key Vault, Storage)에 붙일 해시 접미사 계산에 사용합니다."
  type        = string
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/modules/naming/main.tf" -->
```hcl title="terraform/modules/naming/main.tf"
locals {
  # Cloud Adoption Framework(CAF) 약어를 따르되, 리전은 짧은 코드로 줄여 사용합니다.
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

  # 구독+워크로드로 결정되는 해시. 모든 스택이 같은 값을 재현하므로
  # remote state 없이도 "전역 고유 이름"(ACR, Key Vault, Storage)을 서로 찾아갈 수 있습니다.
  suffix = substr(sha256("${var.subscription_id}/${var.workload}/${var.environment}"), 0, 5)

  names = {
    # Resource groups (수명주기별로 분리)
    rg_tfstate   = "rg-${local.base}-tfstate"
    rg_network   = "rg-${local.base}-network"
    rg_platform  = "rg-${local.base}-platform"
    rg_aks       = "rg-${local.base}-aks"
    rg_aks_nodes = "rg-${local.base}-aks-nodes"
    rg_workload  = "rg-${local.base}-workload"

    # Terraform state (3~24자, 소문자+숫자)
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
  description = "리소스별 이름 맵 (CAF 약어 + 결정적 해시 접미사)"
  value       = local.names
}

output "base" {
  description = "<workload>-<environment>-<region> 형태의 공통 접두 이름"
  value       = local.base
}

output "suffix" {
  description = "전역 고유 이름에 붙는 5자리 해시"
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
```
<!-- /tf:include -->

```bash
terraform -chdir=terraform/modules/naming init -backend=false
terraform -chdir=terraform/modules/naming test        # 5 passed
```

## 부트스트랩 스택 코드

**`versions.tf`** — Terraform/provider 버전을 고정합니다(`~> 5.9` = 5.9 이상 6 미만). 마지막의 주석 처리된 `backend` 블록은 아래 *4단계*에서 사용합니다.

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

  # 부트스트랩 스택은 처음에는 로컬 state 를 사용합니다 (state 저장소를 만드는 스택이므로 "닭과 달걀" 문제).
  # Lab 02 마지막 단계에서 아래 주석을 해제하고 `terraform init -migrate-state -backend-config=../backend.hcl` 로 state 를 이전합니다.
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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/variables.tf" -->
```hcl title="terraform/02-bootstrap/variables.tf"
variable "workload" {
  description = "워크로드 이름 (소문자/숫자 3~8자)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "환경 구분 (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure 리전"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "모든 리소스에 추가로 붙일 태그"
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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/outputs.tf" -->
```hcl title="terraform/02-bootstrap/outputs.tf"
output "backend_hcl" {
  description = "`terraform output -raw backend_hcl > ../backend.hcl` 로 저장해 다른 스택의 partial backend 설정으로 사용합니다."
  value       = <<-EOT
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    use_azuread_auth     = true
  EOT
}

output "tfstate_storage_account_name" {
  description = "state 저장용 스토리지 계정 이름"
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_resource_group_name" {
  description = "state 저장용 리소스 그룹 이름"
  value       = azurerm_resource_group.tfstate.name
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/02-bootstrap/tests/plan.tftest.hcl" -->
```hcl title="terraform/02-bootstrap/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/02-bootstrap test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_storage_account.tfstate.shared_access_key_enabled == false
    error_message = "state 저장소는 계정 키 인증을 꺼야 합니다 (Entra ID 인증만 사용)."
  }

  assert {
    condition     = azurerm_storage_account.tfstate.blob_properties[0].versioning_enabled
    error_message = "state 복구를 위해 Blob 버전 관리를 켜야 합니다."
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

```bash
terraform init -backend-config=../backend.hcl
```

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `AuthorizationPermissionMismatch` (init 시 403) | 역할 할당 전파 지연. 1–5분 후 재시도. `Storage Blob Data Contributor` 가 **컨테이너/계정** 범위에 있는지 확인. |
| `StorageAccountAlreadyTaken` | 이름이 전역 중복. `TF_VAR_workload` 를 바꾸면 해시가 달라집니다. |
| `subscription_id is required` | `ARM_SUBSCRIPTION_ID` 환경 변수 미설정(Lab 01 의 5단계). |
| `Error: Failed to get existing workspaces` | 현재 사용자에게 데이터 평면 역할이 없거나 `use_azuread_auth` 가 빠짐. |

다음 → [Lab 03. 네트워크: VNet · NSG · NAT Gateway · Private DNS](03-network.md)
