<!-- lang-switch -->
**English** | [한국어](ko/04-platform.md)
<!-- /lang-switch -->

# Lab 04. Platform services: ACR · Key Vault · monitoring · identities for AKS

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 30 min | ACR Premium + Managed Grafana + Private Endpoint (about $0.2–0.3 per hour) | `terraform/04-platform` | [03. Networking](03-network.md) |

## What you build in this lab

Before the cluster itself, you create the shared services it "depends on" and **the two managed identities that AKS will use**.

```text
 rg-aksdemo-dev-krc-platform
 ├── id-aks-…-cluster   (UAMI)  control plane ID      ── Network Contributor (network RG), Managed Identity Operator (kubelet ID)
 ├── id-aks-…-kubelet   (UAMI)  node ID               ── AcrPull (ACR)
 ├── acr…               (ACR Premium, zone-redundant) ── Private Endpoint (snet-private-endpoints) + public endpoint for my IP only
 ├── kv-…               (Key Vault, RBAC)             ── Private Endpoint + public endpoint for my IP only
 ├── log-…              (Log Analytics)               ← logs / control plane diagnostic logs
 ├── amw-…              (Azure Monitor workspace)     ← Managed Prometheus metrics
 └── amg-…              (Managed Grafana)             ── Prometheus data source connected automatically
```

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| ECR | `azurerm_container_registry` (ACR) | Private Endpoint, IP firewall, and zone redundancy are **Premium** features. Nodes pull images with the `AcrPull` role. `admin_enabled = false`. |
| ECR lifecycle policy | `retention_policy_in_days` (untagged manifests) | Premium feature. |
| EKS cluster role / node role | **Two UAMIs** + role assignments | AWS attaches a trust policy and a permissions policy to a role, whereas Azure works as "identity resource → role assignment on the target resource". |
| KMS + Secrets Manager + ACM | `azurerm_key_vault` | `rbac_authorization_enabled = true` → the same RBAC model as IAM. A **required argument** in 5.x. |
| VPC Endpoint (Interface) | `azurerm_private_endpoint` + `private_dns_zone_group` | An A record is registered automatically in the Private DNS Zone from Lab 03. |
| CloudWatch Logs | Log Analytics workspace | Query with KQL. A daily ingestion cap (`daily_quota_gb`) prevents runaway costs. |
| Amazon Managed Prometheus (AMP) | `azurerm_monitor_workspace` | Compatible with Prometheus remote write/query. Collection is configured through the DCR/DCRA in Lab 05. |
| Amazon Managed Grafana (AMG) | `azurerm_dashboard_grafana` | Grafana sign-in uses Entra ID. You must be assigned the **Grafana Admin** role to see dashboards. |

> [!TIP]
> **Why create the UAMIs yourself?** AKS also supports a system-assigned identity, but if you create the UAMIs in advance and **finish the role assignments first**, cluster creation is less likely to fail because of permission propagation delays, and the identities and permissions survive even if you recreate the cluster. Separating the kubelet identity also lets you finish the ACR permissions before the cluster is created.

### Role assignments at a glance

![Who can do what: principal → role → scope](diagrams/platform-identities.svg)

| Principal | Role | Scope | Why |
|---|---|---|---|
| cluster UAMI | Network Contributor | Network RG | Join subnets, use the NAT Gateway, allocate internal LB IPs |
| cluster UAMI | Managed Identity Operator | kubelet UAMI | Attach the kubelet identity to the nodes |
| kubelet UAMI | AcrPull | ACR | Pull images |
| Lab user (current user) | AcrPush | ACR | Push / import images (`grant_current_user_roles`; for teams/CI, set it to `false` and grant the role separately to a group or CI principal) |
| Grafana MI | Monitoring Data Reader | Azure Monitor workspace | Query Prometheus |
| Lab user | Grafana Admin | Grafana | Sign in to dashboards (`grant_current_user_roles`) |

## Design decisions (best practices)

| Decision | Why |
|---|---|
| Put ACR/Key Vault behind a **Private Endpoint, and allow only your IP (plus trusted Azure services) on the public endpoint (default Deny)** | Nodes and pods reach them only over the private path. Admin PCs and CI can run `az acr import` and create secrets through the IP allow rule. The firewall's "Allow trusted Azure services" option (Key Vault `bypass = "AzureServices"`, ACR `network_rule_bypass_option` defaulting to `AzureServices`) is turned on, so to lock it down completely, change it to `"None"`. In production, put CI runners inside the VNet and turn public access off entirely. |
| Key Vault **purge protection + 7-day soft delete** | Prevents accidental deletion. But after `destroy`, the name stays reserved for 7 days (if you recreate it with the same name, the provider recovers it) → Lab 11. |
| Strip `/32` from Key Vault IP rules | Key Vault doesn't accept `/31` or `/32`; you must write a single IP instead (`replace(cidr, "/32", "")`). |
| ACR `admin_enabled = false`, `anonymous_pull_enabled = false` | Removes static credentials and anonymous access. |
| Log Analytics `local_authentication_enabled = false` | Allows only Entra (managed identity) authentication instead of shared keys. |
| Collect ACR/Key Vault audit logs with diagnostic settings | Plays the same role as CloudTrail data events. |

## Code

<!-- tf:include path="terraform/04-platform/versions.tf" -->
```hcl title="terraform/04-platform/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "04-platform.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/providers.tf" -->
```hcl title="terraform/04-platform/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # If a soft-deleted Key Vault with the same name exists, recover it instead of creating a new one.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }

    log_analytics_workspace {
      # Permanently delete on destroy so the same name can be reused after the lab.
      permanently_delete_on_destroy = true
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/variables.tf" -->
```hcl title="terraform/04-platform/variables.tf"
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

variable "allowed_ip_ranges" {
  description = <<-EOT
    Administrator public IPs (list of CIDRs) to allow through the ACR / Key Vault firewalls.
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Nodes/pods connect through Private Endpoints, so this list is for "people/CI".
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "enable_grafana" {
  description = "Whether to create Azure Managed Grafana (the Standard SKU is billed hourly)."
  type        = bool
  default     = true
}

variable "grant_current_user_roles" {
  description = <<-EOT
    If true, grants lab roles (AcrPush on ACR, Grafana Admin on Grafana) to the "currently signed-in principal"
    that runs terraform. In team/CI environments, set it to false and assign roles to an Entra group (for people)
    or a separate service principal (for CI) instead.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention period (days)"
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap (GB). A safeguard against runaway lab costs. -1 means unlimited."
  type        = number
  default     = 5
}

variable "key_vault_purge_protection_enabled" {
  description = "Key Vault purge protection. true is recommended in production; once enabled, it cannot be disabled."
  type        = bool
  default     = true
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/main.tf" -->
```hcl title="terraform/04-platform/main.tf"
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

  # Key Vault IP rules do not accept /31 or /32 prefixes, so they are converted to single IPs.
  key_vault_ip_rules = [for cidr in var.allowed_ip_ranges : replace(cidr, "/32", "")]
}

# ---------------------------------------------------------------------------
# Look up the resources created by the 03-network stack by "naming convention".
# Works like AWS `data "aws_vpc"` + tag lookups, and has no remote state dependency.
# ---------------------------------------------------------------------------
data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_subnet" "private_endpoints" {
  name                 = module.naming.names.snet_private_endpoint
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = module.naming.names.rg_network
}

# ---------------------------------------------------------------------------
# Platform (shared services) resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "platform" {
  name     = module.naming.names.rg_platform
  location = var.location
  tags     = local.tags
}
```
<!-- /tf:include -->

**`identity.tf`** — the UAMIs that AKS uses, and their role assignments

<!-- tf:include path="terraform/04-platform/identity.tf" -->
```hcl title="terraform/04-platform/identity.tf"
# ---------------------------------------------------------------------------
# Two managed identities used by AKS (cluster / kubelet)
#
# Mapping to AWS
#   - cluster identity  ≈ EKS cluster IAM role   (the control plane manages LBs, disks, subnets, etc.)
#   - kubelet identity  ≈ EKS node IAM role      (nodes pull images from ACR)
# Instead of "attaching a trust policy to a Role", Azure has you create a resource (UAMI) and
# add a role assignment at the scope of the target resource. There are no long-lived credentials (keys).
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks_cluster" {
  name                = module.naming.names.id_aks_cluster
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = module.naming.names.id_aks_kubelet
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

# Network Contributor on the network resource group so the control plane can use the subnets/NAT Gateway of the BYO VNet.
# (For stricter access, you can narrow the scope to the VNet / subnet.)
resource "azurerm_role_assignment" "cluster_network" {
  scope                = data.azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# To use a BYO kubelet identity, the control plane identity must be able to attach the kubelet identity to the nodes.
resource "azurerm_role_assignment" "cluster_manages_kubelet" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# Lets the nodes (kubelet) pull images from ACR: equivalent to the ECR permissions ecr:GetAuthorizationToken / BatchGetImage.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant AcrPush so the lab user (the currently signed-in user) can push images.
# In team/CI environments, turn this off with grant_current_user_roles = false and assign roles to
# a group/CI principal separately.
resource "azurerm_role_assignment" "operator_acr_push" {
  count = var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
```
<!-- /tf:include -->

**`registry.tf`** — ACR + Private Endpoint + diagnostic settings

<!-- tf:include path="terraform/04-platform/registry.tf" -->
```hcl title="terraform/04-platform/registry.tf"
# ---------------------------------------------------------------------------
# Azure Container Registry  (equivalent to Amazon ECR)
#   - ECR is a per-region/per-account registry plus repositories, while ACR is "one registry = one login server".
#   - Private Endpoint / firewall rules / zone redundancy are available in the Premium SKU.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "Premium"

  admin_enabled            = false # Use Entra ID + RBAC instead of a static admin account
  anonymous_pull_enabled   = false
  zone_redundancy_enabled  = true
  retention_policy_in_days = 7 # Automatically clean up untagged manifests (similar to ECR lifecycle policies)

  # The public endpoint allows only "admin IPs + trusted Azure services (network_rule_bypass_option defaults to
  # AzureServices)" and denies everything else. Nodes/pods pull through the Private Endpoint.
  # (In azurerm 5.x, network_rule_set is a nested attribute, so it is written as `= [{ ... }]`.)
  public_network_access_enabled = true

  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [for cidr in var.allowed_ip_ranges : {
      action   = "Allow"
      ip_range = cidr
    }]
  }]

  tags = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${module.naming.names.acr}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.acr.id]
  }

  tags = local.tags
}

# Send registry login and image push/pull events to Log Analytics (similar to CloudTrail data events)
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`keyvault.tf`**

<!-- tf:include path="terraform/04-platform/keyvault.tf" -->
```hcl title="terraform/04-platform/keyvault.tf"
# ---------------------------------------------------------------------------
# Azure Key Vault  (close to AWS KMS + Secrets Manager + ACM combined into one service)
#   - Stores keys, secrets, and certificates
#   - Uses Azure RBAC (rbac_authorization_enabled) instead of access policies → the same approach as the IAM policy model
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                = module.naming.names.key_vault
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = 7

  # The public endpoint allows only "admin IPs + trusted Azure services (bypass)" and blocks everything else.
  # Pods (CSI Driver) connect through the Private Endpoint. To block trusted Azure services too, change bypass to "None".
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = local.key_vault_ip_rules
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${module.naming.names.key_vault}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-key-vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.key_vault.id]
  }

  tags = local.tags
}

# Secret/key access audit logs (AuditEvent) → Log Analytics. Equivalent to the KMS/SecretsManager events in CloudTrail.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`observability.tf`** — Log Analytics, Azure Monitor workspace, Managed Grafana

<!-- tf:include path="terraform/04-platform/observability.tf" -->
```hcl title="terraform/04-platform/observability.tf"
# ---------------------------------------------------------------------------
# Observability (equivalent to CloudWatch Logs / Amazon Managed Prometheus / Amazon Managed Grafana)
#   - Log Analytics workspace : log storage and KQL queries (CloudWatch Logs + Logs Insights)
#   - Azure Monitor workspace : Managed Prometheus metric store (AMP workspace)
#   - Azure Managed Grafana   : dashboards (AMG)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false # Allow only Entra ID (managed identity) authentication instead of shared keys

  tags = local.tags
}

resource "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_dashboard_grafana" "this" {
  count = var.enable_grafana ? 1 : 0

  name                  = module.naming.names.grafana
  location              = azurerm_resource_group.platform.location
  resource_group_name   = azurerm_resource_group.platform.name
  grafana_major_version = "13"

  api_key_enabled               = false
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  # Automatically connects Managed Prometheus as a Grafana data source.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

# Grant Monitoring Data Reader so Grafana can read Prometheus metrics
resource "azurerm_role_assignment" "grafana_reads_prometheus" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Grant Grafana Admin so the lab user can sign in to Grafana and view dashboards (skipped if grant_current_user_roles = false)
resource "azurerm_role_assignment" "operator_grafana_admin" {
  count = var.enable_grafana && var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_dashboard_grafana.this[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/outputs.tf" -->
```hcl title="terraform/04-platform/outputs.tf"
output "resource_group_name" {
  description = "Resource group for the platform shared services"
  value       = azurerm_resource_group.platform.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = azurerm_log_analytics_workspace.this.id
}

output "monitor_workspace_id" {
  description = "Azure Monitor workspace(Managed Prometheus) ID"
  value       = azurerm_monitor_workspace.this.id
}

output "grafana_endpoint" {
  description = "Managed Grafana URL (null if enable_grafana=false)"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "acr_name" {
  description = "ACR name"
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR login server (e.g., <name>.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "aks_cluster_identity" {
  description = "Control plane UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_cluster.name
}

output "aks_kubelet_identity" {
  description = "kubelet UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_kubelet.name
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/tests/plan.tftest.hcl" -->
```hcl title="terraform/04-platform/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/04-platform test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].ip_rules == toset(["203.0.113.10", "198.51.100.0/24"])
    error_message = "/32 in the Key Vault IP rules must be converted to a single IP."
  }

  assert {
    condition     = azurerm_container_registry.this.sku == "Premium"
    error_message = "ACR must be Premium to use a Private Endpoint."
  }
}

run "plan_without_grafana" {
  command = plan

  variables {
    enable_grafana = false
  }

  assert {
    condition     = length(azurerm_dashboard_grafana.this) == 0
    error_message = "If enable_grafana=false, Grafana must not be created."
  }
}

run "plan_without_operator_roles" {
  command = plan

  variables {
    grant_current_user_roles = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator_acr_push) == 0 && length(azurerm_role_assignment.operator_grafana_admin) == 0
    error_message = "If grant_current_user_roles=false, the ACR/Grafana roles must not be granted to the principal running Terraform."
  }
}

run "rejects_empty_ip_list" {
  command = plan

  variables {
    allowed_ip_ranges = []
  }

  expect_failures = [var.allowed_ip_ranges]
}
```
<!-- /tf:include -->

## Walkthrough

```bash
cd terraform/04-platform
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # about 18 resources (including Grafana)
terraform apply tfplan            # 5–10 min (Grafana and ACR take the longest)
```

> [!NOTE]
> If you'd rather not deploy Grafana, run `export TF_VAR_enable_grafana=false` first. It doesn't affect how the cluster works, and Prometheus collection in Lab 05 still works.

### Verify

```bash
ACR=$(terraform output -raw acr_name); KV=$(terraform output -raw key_vault_name)

az acr show -n "$ACR" --query "{sku:sku.name, adminUser:adminUserEnabled, publicAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, zoneRedundancy:zoneRedundancy}" -o json

az keyvault show -n "$KV" --query "{rbac:properties.enableRbacAuthorization, purgeProtection:properties.enablePurgeProtection, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}" -o json

# Private Endpoints and DNS records (check that A records were created in the Private DNS Zone)
az network private-endpoint list -g "$(terraform output -raw resource_group_name)" -o table
az network private-dns record-set a list -g "$(az group list --query "[?ends_with(name,'-network')].name | [0]" -o tsv)" \
   -z privatelink.azurecr.io -o table

# Image import test: server-side copy from an external registry → ACR (like fetching an image from ECR)
az acr import -n "$ACR" --source mcr.microsoft.com/cbl-mariner/busybox:2.0 --image demo/busybox:2.0
az acr repository list -n "$ACR" -o table
```

> [!TIP]
> To access Grafana, open the URL from `terraform output grafana_endpoint` and sign in with Entra ID. *Managed Prometheus* is already connected as a data source (metrics start to accumulate from Lab 05 onward).

### Automated verification script

Checks the firewalls and Private Endpoints of ACR and Key Vault, Log Analytics, the Prometheus workspace, and the UAMIs for AKS together with their **role assignments**, such as kubelet → AcrPull (read-only).

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 04-platform
```

<!-- tf:include path="scripts/verify/04-platform.sh" -->
```bash title="scripts/verify/04-platform.sh"
#!/usr/bin/env bash
# Lab 04 verification: checks ACR · Key Vault · Log Analytics · Prometheus/Grafana · the identities for AKS
# and their role assignments (read-only).
#   AWS comparison: ECR · KMS/Secrets Manager · CloudWatch Logs · Managed Prometheus/Grafana · IAM Role + policies
# Usage: scripts/verify.sh 04-platform
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Is there at least one Private Endpoint connection, and are all of them Approved?
# (the JSON nesting differs by az version, so both shapes are accepted)
PE_APPROVED='[.[]? | (.privateLinkServiceConnectionState // .properties.privateLinkServiceConnectionState).status] | length >= 1 and all(.[]; . == "Approved")'

verify_stack() {
  local rg net_rg acr kv law_id law_name amw_id grafana acr_json kv_json law amw
  local id_cluster id_kubelet cluster_pid kubelet_pid net_rg_id
  rg="$(tf_out 04-platform resource_group_name)"
  net_rg="$(tf_out 03-network resource_group_name)"
  acr="$(tf_out 04-platform acr_name)"
  kv="$(tf_out 04-platform key_vault_name)"
  law_id="$(tf_out 04-platform log_analytics_workspace_id)"
  amw_id="$(tf_out 04-platform monitor_workspace_id)"
  grafana="$(tf_out 04-platform grafana_endpoint)"
  id_cluster="$(tf_out 04-platform aks_cluster_identity)"
  id_kubelet="$(tf_out 04-platform aks_kubelet_identity)"

  section "04-platform · platform services (${rg:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 04-platform?"
    return
  fi

  # --- ACR (ECR) ---
  acr_json="$(azj acr show -g "$rg" -n "$acr")"
  expect_eq "ACR SKU (Private Endpoint requires Premium)" "$(jv "$acr_json" .sku.name)" "Premium"
  expect_eq "ACR admin user enabled" "$(jv "$acr_json" .adminUserEnabled)" "false"
  expect_eq "ACR anonymous pull allowed" "$(jv "$acr_json" .anonymousPullEnabled)" "false"
  expect_eq "ACR default action for public access (firewall)" "$(jv "$acr_json" .networkRuleSet.defaultAction)" "Deny"
  jq_ok "ACR Private Endpoint approved" "$acr_json" ".privateEndpointConnections | $PE_APPROVED"

  # --- Key Vault (KMS + Secrets Manager) ---
  kv_json="$(azj keyvault show -n "$kv")"
  expect_eq "Key Vault permission model = Azure RBAC" "$(jv "$kv_json" .properties.enableRbacAuthorization)" "true"
  expect_eq "Key Vault default action for public access (firewall)" "$(jv "$kv_json" .properties.networkAcls.defaultAction)" "Deny"
  jq_warn "Key Vault purge protection on (recommended for production)" "$kv_json" '.properties.enablePurgeProtection == true'
  jq_ok "Key Vault Private Endpoint approved" "$kv_json" ".properties.privateEndpointConnections | $PE_APPROVED"

  # --- Observability ---
  law_name="${law_id##*/}"
  law="$(azj monitor log-analytics workspace show -g "$rg" -n "$law_name")"
  expect_eq "Log Analytics local (shared key) auth disabled" "$(jv "$law" .features.disableLocalAuth)" "true"
  expect_set "Log Analytics retention (days)" "$(jv "$law" .retentionInDays)"
  amw="$(azj resource show --ids "$amw_id")"
  expect_eq "Azure Monitor workspace (Managed Prometheus) state" "$(jv "$amw" .properties.provisioningState)" "Succeeded"
  if [ -n "$grafana" ]; then
    pass "Managed Grafana: $grafana"
  else
    skip "No Managed Grafana (enable_grafana = false)"
  fi

  # --- Managed Identities for AKS and their role assignments (equivalent to an IAM Role + attached policies) ---
  cluster_pid="$(jv "$(azj identity show -g "$rg" -n "$id_cluster")" .principalId)"
  kubelet_pid="$(jv "$(azj identity show -g "$rg" -n "$id_kubelet")" .principalId)"
  expect_set "Control plane UAMI ($id_cluster)" "$cluster_pid"
  expect_set "kubelet UAMI ($id_kubelet)" "$kubelet_pid"
  net_rg_id="$(az group show -n "$net_rg" --query id -o tsv 2>/dev/null)"
  if [ -n "$kubelet_pid" ] && [ -n "$cluster_pid" ]; then
    has_role "kubelet → AcrPull (ACR)" "$kubelet_pid" "AcrPull" "$(jv "$acr_json" .id)"
    has_role "Control plane → Network Contributor (network RG)" "$cluster_pid" "Network Contributor" "$net_rg_id"
  fi
}

# You can also run it directly (scripts/verify/04-platform.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## Common issues

| Symptom | Cause / fix |
|---|---|
| `MissingSubscriptionRegistration` | The resource provider isn't registered → [step 3 of Lab 01](01-prerequisites.md). Check `Microsoft.Dashboard` and `Microsoft.Monitor` in particular. |
| `az acr import` fails with `403`/`denied` | Public access is allowed only from the IPs in `allowed_ip_ranges`. Check whether your current IP has changed, then run `terraform apply`. |
| `az keyvault secret set` fails with `Forbidden` | The Key Vault firewall (IP) or a data plane role (Key Vault Secrets Officer) is missing. Role propagation can take a few minutes. |
| Grafana `ZoneRedundancy`/version error | As of azurerm 5.9, `grafana_major_version` can be 12 or 13. If the region has constraints, use `enable_grafana=false`. |
| Key Vault name already exists (soft-deleted) | The provider's `recover_soft_deleted_key_vaults = true` recovers it. If it was deleted earlier with purge protection on, the only option for 7 days is to recover it. |

Next → [Lab 05. AKS cluster](05-aks.md)
