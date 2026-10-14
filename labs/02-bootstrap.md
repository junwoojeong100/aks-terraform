<!-- lang-switch -->
**English** | [한국어](ko/02-bootstrap.md)
<!-- /lang-switch -->

# Lab 02. Terraform remote state: S3 + DynamoDB ↔ Blob Storage

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 20 min | Almost none | `terraform/02-bootstrap`, `terraform/modules/naming` | [01. Prerequisites](01-prerequisites.md) |

## What you build in this lab

You build a **remote state store** (a Storage Account + container) that every stack shares, and a **shared module (`naming`)** that makes every stack follow the same naming convention.

![Terraform stack layers and execution order](diagrams/stack-layers.svg)

The state store has the following structure.

```text
 rg-aksdemo-dev-krc-tfstate
 └── sttfstateaksdemo<hash>  (Storage Account, ZRS, key authentication disabled)
     └── container "tfstate"
         ├── 03-network.tfstate     ← Lab 03
         ├── 04-platform.tfstate    ← Lab 04
         ├── 05-aks.tfstate         ← Lab 05
         └── ...
```

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| S3 bucket | Storage Account + **Blob container** | The Storage Account name must be **globally unique** (3–24 lowercase letters and digits). |
| DynamoDB lock table | (not needed) | The azurerm backend handles locking with a **blob lease**. |
| S3 Versioning | `blob_properties.versioning_enabled` | Roll back an accidentally overwritten state to a previous version. |
| Block Public Access | `allow_nested_items_to_be_public = false` | Blocks public access to containers. |
| IAM policy (s3:GetObject/PutObject) | RBAC **Storage Blob Data Contributor** | Data plane roles are separate. `Contributor` (a management plane role) alone can't read or write blobs. |
| Access keys/credentials | `shared_access_key_enabled = false` + `use_azuread_auth = true` | Turns off account keys entirely and allows only Entra ID authentication. |

> [!TIP]
> **Why we split state per stack**: The network (almost never changes) → platform services → cluster → workloads differ in how often they change and in who is authorized to change them. Splitting state reduces the blast radius of a change and makes it less likely that you touch the VNet by accident.
> Stacks are linked through a **naming convention + data sources** instead of `terraform_remote_state` (you don't need to share access to the state files, and no circular dependencies arise).

## Shared module: `modules/naming`

In Azure, **resource naming conventions** (Cloud Adoption Framework abbreviations) and **globally unique names** (ACR, Key Vault, Storage) are a significant concern. This module builds a 5-character hash from `subscription ID + workload + environment`, so it **reproduces the same names** no matter which stack calls it.

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

`terraform test` is Terraform's built-in testing framework. Since this is pure logic with no provider, it runs right away.

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

## Bootstrap stack code

**`versions.tf`** — The `terraform {}` settings of a stack. Every stack has one, and it covers three things:

- `required_version`: the Terraform CLI versions that may run the stack (`~> 1.16` = 1.16 or later, below 2.0).
- `required_providers`: where each provider comes from and which versions are allowed (`~> 5.9` = 5.9 or later, below 6). `terraform init` records the exact versions it picked, with checksums, in `.terraform.lock.hcl`. This repository commits that file so that everyone gets the same provider builds.
- `backend`: where the state is stored. The block fixes only the state `key` and Entra ID authentication; the storage account and container come from `backend.hcl` (step 3). This stack is the exception: it creates the state storage itself, so the block at the end is commented out and used only in *step 4* below.

The `provider` blocks themselves live in `providers.tf`. If you come from AWS, this file plays the same role as `required_providers` and `backend "s3"` in an AWS project.

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

**`providers.tf`** — azurerm 5.x doesn't register Resource Providers automatically (`none`).

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

**`main.tf`** — The storage account uses ZRS (zone-redundant), disables key authentication, and enables versioning and soft delete.

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

## Walkthrough

### Step 1. Check the environment variables

```bash
source env.sh 2>/dev/null || true   # If you saved it in Lab 01
echo $ARM_SUBSCRIPTION_ID $TF_VAR_workload $TF_VAR_environment $TF_VAR_location
```

### Step 2. Plan and apply

There is no state store yet, so the first run uses **local state**.

```bash
cd terraform/02-bootstrap
terraform init
terraform plan -out tfplan        # 4 resources: resource group, Storage Account, container, role assignment
terraform apply tfplan
```

> [!NOTE]
> If you `apply` the plan saved with `-out tfplan` as is, only the "reviewed changes" are applied (the standard pattern for production pipelines).

### Step 3. Save the backend configuration for the other stacks

`backend.hcl` is a partial backend configuration. To avoid hardcoding the storage account name in code, you inject it with `-backend-config`.

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
> `backend.hcl` contains no secrets (key authentication isn't used), but it differs per environment, so it isn't committed to the repository (it is listed in `terraform/.gitignore`).

### Step 4. (Optional) Migrate the bootstrap stack's state to the remote backend too

1. Uncomment the `backend "azurerm"` block in `terraform/02-bootstrap/versions.tf`.
2. The role assignment can take 1–5 minutes to propagate. If the command below fails with `403`, wait a moment and run it again.

```bash
terraform init -migrate-state -backend-config=../backend.hcl
# "Do you want to copy existing state to the new backend?" → yes
```

> [!NOTE]
> This edit belongs to your own environment, so don't commit it. The repository keeps the block commented out so that Lab 02 starts with local state for everyone (the CI of this repository fails if the block is enabled). Lab 11 step 2 comments it out again.

### Step 5. Verify

```bash
ST=$(terraform output -raw tfstate_storage_account_name)

# List containers/blobs with your Entra ID sign-in (no account key is used)
az storage blob list --account-name "$ST" --container-name tfstate --auth-mode login -o table

# Check that key authentication is off → the result must be false
az storage account show -n "$ST" --query allowSharedKeyAccess -o tsv
```

**Check the locking behavior**: If you run `terraform plan` in two terminals at the same time, the second one waits or fails with `Error acquiring the state lock` (blob lease). If you pass `-lock-timeout=60s`, it waits until the lock is released.

## The init pattern used by all later stacks

In stacks 03–10 the `backend "azurerm"` block in `versions.tf` is already enabled and fixes only that stack's state `key`. `-backend-config` supplies the storage account and container from `backend.hcl`:

```bash
terraform init -backend-config=../backend.hcl
```

### Automated verification script

This runs the manual checks from step 5 (key authentication blocked, versioning, container, state files) in one go. It is **read-only** and returns a `✓ passed / ✗ failed / ! warnings` summary and an exit code (1 if anything failed).

```bash
cd ../..                          # Run from the repository root
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

## Common issues

| Symptom | Cause / fix |
|---|---|
| `AuthorizationPermissionMismatch` (403 during init) | Role assignment propagation delay. Retry after 1–5 minutes. Check that `Storage Blob Data Contributor` is assigned at the **container/account** scope. |
| `StorageAccountAlreadyTaken` | The name is already taken globally. Changing `TF_VAR_workload` changes the hash. |
| `subscription_id is required` | The `ARM_SUBSCRIPTION_ID` environment variable isn't set (step 5 of Lab 01). |
| `Error: Failed to get existing workspaces` | The current user has no data plane role, or `use_azuread_auth` is missing. |

Next → [Lab 03. Networking: VNet · NSG · NAT Gateway · Private DNS](03-network.md)
