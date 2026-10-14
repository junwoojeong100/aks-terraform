<!-- lang-switch -->
**English** | [한국어](ko/05-aks.md)
<!-- /lang-switch -->

# Lab 05. AKS cluster (Standard): how it differs from EKS

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 40 min (apply 15–25 min) | **About $1.7–2 per hour** (Standard tier + 6 or more nodes) | `terraform/05-aks` | [04. Platform services](04-platform.md) |

## What you build in this lab

![AKS cluster layout (Standard)](diagrams/aks-cluster.svg)

## Comparison for EKS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| `aws_eks_cluster` | `azurerm_kubernetes_cluster` | Both control planes are managed. The **uptime SLA starts at `sku_tier = "Standard"`** (the Free tier has no SLA). |
| `aws_eks_node_group` / ASG | `default_node_pool` + `azurerm_kubernetes_cluster_node_pool` | You separate the **System pool** (required, for system pods only) from the **User pool**. Nodes = VMSS. |
| Nodes are EC2 instances in your VPC | **Node resource group** (`node_resource_group`) | The VMSS, load balancer, and disks are created in an RG separate from the cluster RG. Don't modify them directly. |
| VPC CNI (pod = VPC IP) | `network_plugin = azure` + `network_plugin_mode = overlay` | Pods use `pod_cidr` → saves VNet IPs. You can't reach pod IPs directly from outside the cluster (use Pod Subnet mode if you need that). |
| (Install Calico/Cilium separately) | `network_data_plane = cilium`, `network_policy = cilium` | Managed Cilium. Replaces kube-proxy + enforces NetworkPolicy + (optional) ACNS observability/security. |
| Public/private endpoint + CIDR restriction | `api_server_access_profile` (VNet Integration + `authorized_ip_ranges`) / `private_cluster_enabled` | VNet Integration projects the API server into an internal load balancer (ILB) in your subnet (no private endpoint or DNS zone needed). |
| aws-auth ConfigMap / access entries | `azure_active_directory_role_based_access_control` + role assignments | **Azure RBAC for Kubernetes**: roles such as "Azure Kubernetes Service RBAC Cluster Admin" control Kubernetes permissions too. |
| (No local admin) | `local_account_disabled = true` | By default, AKS has a static-certificate kubeconfig (the local account) → **always turn it off**. |
| IRSA / Pod Identity | `oidc_issuer_enabled` + `workload_identity_enabled` | Lab 06. In azurerm 5.x, the OIDC issuer defaults to `true`. |
| EKS upgrades | `kubernetes_version` (at creation) + `automatic_upgrade_channel` + `maintenance_window_*` | AKS applies patches automatically during the maintenance window; for minor versions, run a preflight check first, then upgrade step by step with `az aks upgrade` (Lab 09). After creation AKS manages the version, so Terraform ignores version changes (`ignore_changes`). |
| Karpenter / Cluster Autoscaler | `auto_scaler_profile` (CA) / `node_provisioning_profile` (NAP) | This lab uses the Cluster Autoscaler (`mode = "Manual"`). You try NAP in Lab 10 (Automatic). |

## Design decisions (best practices)

| Setting | Value | Why (WAF / baseline architecture recommendations) |
|---|---|---|
| `sku_tier` | `Standard` | Uptime SLA and the cost analysis add-on. Required for production. |
| `kubernetes_version` | `"1.36"` (latest GA as of 2026-10) | This is a **minor alias at creation time**. AKS manages later patch/minor versions, so `lifecycle { ignore_changes }` stops Terraform from reverting them (this prevents a permanent diff caused by the alias differing from the actual patch version). The AKS default is 1.35, and N-1 (1.35) is also a good choice for conservative operations. 1.37 is due to go GA (currently in preview). A `check` block warns if the region doesn't support the version. |
| `automatic_upgrade_channel` / `node_os_upgrade_channel` | `patch` / `NodeImage` | Security patches are applied automatically during the maintenance window; **you run minor upgrades yourself after a preflight check (Lab 09)**. Control the timing with `maintenance_window_*`. |
| System pool | D4ds_v5 ×3 (1 per zone), `only_critical_addons_enabled` | Separates system pods from apps and tolerates a zone failure. 4 vCPUs or more recommended. |
| User pool | D4ds_v5 ×3–6 (autoscaler) | Apps only. A minimum of 3 nodes (the pool spans 3 zones, so one node per zone is typical) keeps the apps available even if a zone fails. Zone balance when the autoscaler scales out is best-effort. If you need strict balance, create a separate pool per zone and use `balance_similar_node_groups`. |
| OS | `AzureLinux3` + Ephemeral OS disk (64GB) | Lightweight, hardened OS; fast node replacement; no disk cost. (Azure Linux 2.0 images are removed on 2026-10-31) |
| Networking | CNI Overlay + Cilium, `userAssignedNATGateway` | Saves IPs, eBPF data plane, fixed egress IP. kubenet isn't recommended for new clusters. |
| API server | VNet Integration + authorized IP ranges | Public, but reachable only from your IP. You can switch to a fully private cluster with `enable_private_cluster = true` (see the advanced experiments below). |
| Authentication | Entra + Azure RBAC, `local_account_disabled = true` | Access only through auditable identities. No static kubeconfig. |
| Add-ons | Azure Policy, Key Vault CSI, Image Cleaner, KEDA, VPA, Cost analysis | Governance, secrets, and cost visibility. |
| Observability | Managed Prometheus + Container Insights (DCR) + control plane diagnostic logs | Collects mainly `kube-audit-admin` (cheap). Prometheus recording rules support the default Grafana dashboards. |
| Not included | Azure Firewall egress, App Gateway+WAF, multi-region | Cost/complexity. See the "production checklist" in the appendix. |

> [!IMPORTANT]
> **Changes between azurerm 4.x and 5.x**: The `node_provisioning_profile { mode = "Manual" }` block is **required** in 5.x (without it, `validate` fails). The `oidc_issuer_enabled` default is `true` in 5.x, `enable_auto_scaling` in `default_node_pool` was renamed to `auto_scaling_enabled`, and changing `os_disk_type`/`only_critical_addons_enabled`/`vm_size` and similar attributes requires `temporary_name_for_rotation`.

> [!NOTE]
> **Why we use AzAPI**: azurerm 5.9 doesn't yet expose the settings for *control plane metrics* and *Gateway API* (Managed Gateway API CRDs + the application routing Istio implementation). AzAPI's `azapi_update_resource` applies a **partial update** to the same cluster. The two updates are serialized with `depends_on` so they never PUT to the same cluster at the same time.

## Code

<!-- tf:include path="terraform/05-aks/versions.tf" -->
```hcl title="terraform/05-aks/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    # New AKS features that azurerm doesn't support yet (Gateway API, control plane metrics) are enabled through AzAPI.
    # (Similar to using the awscc provider on AWS for new APIs that the aws provider hasn't caught up with.)
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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/providers.tf" -->
```hcl title="terraform/05-aks/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# AzAPI likewise uses ARM_SUBSCRIPTION_ID and the Azure CLI sign-in as is.
provider "azapi" {}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/variables.tf" -->
```hcl title="terraform/05-aks/variables.tf"
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
    Public IPs of administrators allowed to access the Kubernetes API server (list of CIDRs).
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Not used when enable_private_cluster = true.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version (minor alias) used only when the cluster is first created.
    As of 2026-10, the latest GA version is 1.36 and the AKS default is 1.35.
    After creation, AKS manages the version (patches: automatic_upgrade_channel = "patch"; minors: the Lab 09 procedure),
    so Terraform ignores changes to this value.
    To check: az aks get-versions --location koreacentral -o table
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be in the form 1.36 or 1.36.4."
  }
}

variable "sku_tier" {
  description = "AKS control plane tier. Standard includes the uptime SLA (99.95% with availability zones). Free has no SLA."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of Free, Standard, or Premium."
  }
}

variable "enable_private_cluster" {
  description = <<-EOT
    If true, the API server is exposed only on a private IP (fully private).
    In that case, kubectl and the Terraform kubernetes provider can connect only from inside the VNet (or via VPN/Bastion).
    The lab default is false: API Server VNet Integration + authorized IP ranges.
  EOT
  type        = bool
  default     = false
}

variable "zones" {
  description = "Availability zones to spread the node pools across"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  description = "System node pool VM size (at least 4 vCPUs recommended)"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_min_count" {
  description = "Minimum node count for the System node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "system_node_max_count" {
  description = "Maximum node count for the System node pool"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "User node pool VM size"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "user_node_min_count" {
  description = "Minimum node count for the User node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "user_node_max_count" {
  description = "Maximum node count for the User node pool"
  type        = number
  default     = 6
}

variable "enable_spot_pool" {
  description = "Whether to add a Spot VM node pool (equivalent to EC2 Spot; for batch/fault-tolerant workloads)"
  type        = bool
  default     = false
}

variable "enable_gateway_api" {
  description = "Enable the Managed Gateway API CRDs + the application routing Gateway API implementation (approuting-istio)"
  type        = bool
  default     = true
}

variable "enable_defender" {
  description = "Declare the Microsoft Defender for Containers profile on the cluster (the subscription-level plan is enabled in 08-governance). Requires defender_log_analytics_workspace_id."
  type        = bool
  default     = false
}

variable "defender_log_analytics_workspace_id" {
  description = <<-EOT
    Resource ID of the Log Analytics workspace that the Defender sensor sends its data to (used when enable_defender = true).
    The workspace must allow local (shared key) authentication: the Defender sensor does not support workspaces with
    local_authentication_enabled = false, and its publisher pods crash-loop. The platform workspace from 04-platform
    disables local authentication on purpose, so do not use it here. If the subscription's Defender auto-provisioning policy
    already attached the profile, reuse its workspace:
      az aks show -g <rg> -n <cluster> --query securityProfile.defender.logAnalyticsWorkspaceResourceId -o tsv
  EOT
  type        = string
  default     = null
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default. In team/CI environments, set it to false and specify Entra groups
    in admin_principal_ids (permissions stay stable even when the executing principal changes).
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (Local accounts are disabled, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "maintenance_utc_offset" {
  description = "UTC offset used for the maintenance windows (planned maintenance)"
  type        = string
  default     = "+09:00"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR. Must not overlap with the VNet or on-premises ranges. Use the same value as pod_cidr in 03-network (the node NSG allow rule)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "kube-dns Service IP (an address within service_cidr)"
  type        = string
  default     = "10.0.0.10"
}
```
<!-- /tf:include -->

**`main.tf`** — lookups of resources from earlier stacks, the version `check`, and the resource group

<!-- tf:include path="terraform/05-aks/main.tf" -->
```hcl title="terraform/05-aks/main.tf"
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

# ---------------------------------------------------------------------------
# Look up the outputs of the earlier stacks (03-network, 04-platform) by naming convention
# ---------------------------------------------------------------------------
data "azurerm_subnet" "aks_nodes" {
  name                 = module.naming.names.snet_aks_nodes
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_subnet" "aks_apiserver" {
  name                 = module.naming.names.snet_aks_apiserver
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_user_assigned_identity" "cluster" {
  name                = module.naming.names.id_aks_cluster
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_user_assigned_identity" "kubelet" {
  name                = module.naming.names.id_aks_kubelet
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  resource_group_name = module.naming.names.rg_platform
}

# List of GA Kubernetes versions supported in the region (same information as az aks get-versions)
data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

# A check block is a "warning-only validation" that does not block apply. An unsupported version is reported at plan time.
check "kubernetes_version_is_supported" {
  assert {
    condition = anytrue([
      for v in data.azurerm_kubernetes_service_versions.current.versions :
      v == var.kubernetes_version || startswith(v, "${var.kubernetes_version}.")
    ])
    error_message = "kubernetes_version=${var.kubernetes_version} is not a supported GA version in ${var.location}. Supported versions: ${join(", ", data.azurerm_kubernetes_service_versions.current.versions)}"
  }
}

# ---------------------------------------------------------------------------
# Cluster resource group (the node resource group 'rg-...-aks-nodes' is created and managed separately by AKS)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "aks" {
  name     = module.naming.names.rg_aks
  location = var.location
  tags     = local.tags
}
```
<!-- /tf:include -->

**`cluster.tf`** — the cluster and node pools (the core of this lab)

<!-- tf:include path="terraform/05-aks/cluster.tf" -->
```hcl title="terraform/05-aks/cluster.tf"
# ---------------------------------------------------------------------------
# AKS cluster (Standard mode: you design and operate the platform yourself)
#
# Compared with EKS
#   - Azure operates the control plane (same as EKS). sku_tier = Standard provides the uptime SLA.
#   - Nodes are "node pools" built on VMSS (Virtual Machine Scale Sets) (≈ EKS managed node group / ASG)
#   - Node VMs are created in a separate "node resource group" (rg-...-aks-nodes).
#     With EKS, the EC2 instances appear directly in your own account.
#   - Authentication uses Entra ID + Azure RBAC (≈ IAM + EKS access entries);
#     pod permissions use Workload Identity (≈ IRSA/Pod Identity)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  node_resource_group = module.naming.names.rg_aks_nodes
  dns_prefix          = module.naming.names.aks

  # --- Version / upgrades --------------------------------------------------------
  # kubernetes_version is used only at creation time (see lifecycle.ignore_changes below).
  # After that, AKS applies patches automatically.
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  support_plan              = "KubernetesOfficial"
  automatic_upgrade_channel = "patch"     # latest patch auto-applied in the maintenance window (minor: manual, Lab 09)
  node_os_upgrade_channel   = "NodeImage" # node OS image auto-replaced in the weekly maintenance window

  # --- Security: Entra ID auth + Azure RBAC, local accounts (static kubeconfig) disabled ---
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # --- Workload identity (equivalent to IRSA / EKS Pod Identity) -----------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- Governance / operations features ------------------------------------------
  azure_policy_enabled         = true # Azure Policy for Kubernetes (based on OPA Gatekeeper)
  image_cleaner_enabled        = true # automatically removes unused, vulnerable images
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free" # per-namespace/workload cost analysis (Standard tier or higher)

  # --- API server access ---------------------------------------------------------
  # API Server VNet Integration: projects the API server endpoint into a delegated subnet in your own VNet.
  # Like the EKS "public + private endpoint with restricted CIDRs" setup, authorized IP ranges limit public access.
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = data.azurerm_subnet.aks_apiserver.id
    authorized_ip_ranges                = var.enable_private_cluster ? null : var.allowed_ip_ranges
  }

  # --- Identity: use your own UAMI (roles already assigned in 04-platform) -------
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # --- Network: Azure CNI Overlay + Cilium, outbound through your own NAT Gateway ----
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # pods use a separate CIDR: almost no VNet IPs (the key difference from EKS VPC CNI)
    network_data_plane  = "cilium"  # eBPF data plane (replaces kube-proxy)
    network_policy      = "cilium"  # enforces NetworkPolicy

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway" # egress through the NAT Gateway attached to the subnet in 03-network
  }

  # --- Node pools: the System pool is dedicated to system components -------------
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    zones                        = var.zones
    vnet_subnet_id               = data.azurerm_subnet.aks_nodes.id
    orchestrator_version         = var.kubernetes_version
    os_sku                       = "AzureLinux3"
    os_disk_type                 = "Ephemeral" # OS on the node's local disk: fast, no disk charge
    os_disk_size_gb              = 64
    only_critical_addons_enabled = true # CriticalAddonsOnly taint → app pods go to the User pool
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count

    # Name of the temporary pool used for rotation when changing properties such as vm_size
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = local.tags
  }

  # Uses Cluster Autoscaler (same family as EKS cluster-autoscaler) → "Manual" mode: you manage the node pools.
  # To use Karpenter-based Node Auto Provisioning, set mode = "Auto" (the node pool autoscaler must then be off).
  # AKS Automatic uses NAP by default → see Lab 10.
  node_provisioning_profile {
    mode = "Manual"
  }

  auto_scaler_profile {
    balance_similar_node_groups   = true # balance node counts across pools in different availability zones
    expander                      = "least-waste"
    skip_nodes_with_local_storage = true # explicitly set to the AKS default (the block makes Terraform send false)
    skip_nodes_with_system_pods   = true
  }

  # --- Maintenance windows: control "when" upgrades happen (no EKS equivalent) ----
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  # --- Add-ons -------------------------------------------------------------------
  # Secrets Store CSI Driver + Azure Key Vault Provider (≈ AWS Secrets Manager CSI provider)
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Container Insights (logs): the ama-logs agent sends data to Log Analytics. The DCR is defined in monitoring.tf.
  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus (metrics): the DCR/DCE are defined in monitoring.tf.
  monitor_metrics {}

  # KEDA (event-driven autoscaling) + VPA (requests/limits recommendations)
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []

    content {
      log_analytics_workspace_id = var.defender_log_analytics_workspace_id
    }
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !var.enable_defender || var.defender_log_analytics_workspace_id != null
      error_message = "If enable_defender = true, set defender_log_analytics_workspace_id to a workspace that allows local authentication. The platform workspace does not, and the Defender sensor cannot use it."
    }

    # Terraform sets the version only at creation time; after that, the AKS auto-upgrade channel manages it.
    # (Through azurerm 5.9, after an automatic patch upgrade the alias "1.36" no longer matches the actual version
    # "1.36.6", so every plan shows a diff. An improvement is planned for 5.10.)
    # For the minor upgrade procedure and how to manage the version directly with Terraform, see Lab 09.
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User node pool: for application workloads (equivalent to an EKS managed node group)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  os_disk_type         = "Ephemeral"
  os_disk_size_gb      = 64
  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  temporary_name_for_rotation = "usertmp"

  node_labels = {
    "workload-type" = "general"
  }

  upgrade_settings {
    max_surge                     = "33%"
    drain_timeout_in_minutes      = 30
    node_soak_duration_in_minutes = 0
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version] # same reason as the cluster (auto-upgrade manages the version)
  }
}

# ---------------------------------------------------------------------------
# (Optional) Spot node pool: for interruptible batch/CI workloads (equivalent to EC2 Spot)
# Scales down to 0 nodes, and pods are scheduled only if they have a toleration.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # capped at the on-demand price

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 5

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version]
  }
}
```
<!-- /tf:include -->

**`monitoring.tf`** — Managed Prometheus / Container Insights / diagnostic settings

<!-- tf:include path="terraform/05-aks/monitoring.tf" -->
```hcl title="terraform/05-aks/monitoring.tf"
# ---------------------------------------------------------------------------
# Observability wiring: AKS ↔ Managed Prometheus / Container Insights
#
# On AWS (CloudWatch Container Insights, AMP) you wire up "agent + workspace + IAM" yourself,
# whereas on Azure a Data Collection Rule (DCR) defines "what to send where",
# and a Data Collection Rule Association (DCRA) attaches the DCR to the AKS cluster.
# ---------------------------------------------------------------------------

# --- Managed Prometheus ----------------------------------------------------------
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = module.naming.names.dce_prometheus
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = module.naming.names.dcr_prometheus
  location                    = azurerm_resource_group.aks.location
  resource_group_name         = azurerm_resource_group.aks.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  description                 = "Managed Prometheus: sends AKS metrics to the Azure Monitor workspace"

  destinations {
    monitor_account {
      monitor_account_id = data.azurerm_monitor_workspace.this.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }

  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = "dcra-${module.naming.names.aks}-prometheus"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "Deleting this stops Prometheus metric collection for this AKS cluster."
}

# The azurerm monitor_metrics block doesn't expose control plane metrics (apiserver, etcd, etc.), so enable them via AzAPI.
# Enable them only after the DCRA has been created, so the collector pods don't go into CrashLoop.
resource "azapi_update_resource" "control_plane_metrics" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      azureMonitorProfile = {
        metrics = {
          enabled = true # already on via the monitor_metrics block; the API schema requires it, so it is sent too
          controlPlane = {
            enabled = true
          }
        }
      }
    }
  }

  # A PUT on the same cluster that overlaps with node pool creation/changes fails with 409 AnotherOperationInProgress,
  # so this runs after the node pools.
  depends_on = [
    azurerm_monitor_data_collection_rule_association.prometheus,
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_kubernetes_cluster_node_pool.spot,
  ]
}

# --- Container Insights (logs) ---------------------------------------------------
locals {
  # Cost-optimized setup: Prometheus handles the performance metrics (Perf, InsightsMetrics),
  # so only the log and inventory streams are collected.
  container_insights_streams = [
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
    "Microsoft-KubeServices",
    "Microsoft-KubePVInventory",
  ]
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = module.naming.names.dcr_container_insights
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  description         = "Container Insights: sends container logs and Kubernetes inventory to Log Analytics"

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = local.container_insights_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = local.container_insights_streams

      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Exclude"
          namespaces             = ["kube-system", "gatekeeper-system", "azure-arc"]
          enableContainerLogV2   = true
        }
      })
    }
  }

  tags = local.tags
}

# Container Insights requires the association name to be exactly "ContainerInsightsExtension".
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Deleting this stops Container Insights log collection for this AKS cluster."
}

# --- Control plane logs (equivalent to EKS control plane logging → CloudWatch Logs) ----
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # use resource-specific tables such as AKSAudit/AKSControlPlane

  dynamic "enabled_log" {
    for_each = toset([
      "kube-audit-admin", # collects audit logs for change (write) operations only: much cheaper than kube-audit
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard", # Entra ID authentication/authorization logs
    ])

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`prometheus-rules.tf`** — the recording rules used by the default Grafana dashboards (copy and use as is)

<!-- tf:include path="terraform/05-aks/prometheus-rules.tf" -->
```hcl title="terraform/05-aks/prometheus-rules.tf"
# ---------------------------------------------------------------------------
# Prometheus Recording Rules
#
# Azure Managed Grafana's default Kubernetes dashboards ("Kubernetes / Compute Resources / ...")
# use the time series that the recording rules below pre-compute.
# The portal/CLI creates them automatically when you enable Managed Prometheus,
# but with Terraform you have to define them yourself.
# (Source: AddonTerraformTemplate in the Azure/prometheus-collector repo – Node / Kubernetes rule groups for Linux)
# The rules are long, so just "copy and use this file as is".
# ---------------------------------------------------------------------------
resource "azurerm_monitor_alert_prometheus_rule_group" "node_recording_rules" {
  name                = "NodeRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Node Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "instance:node_num_cpu:sum"
    expression = <<-EOT
      count without (cpu, mode) (  node_cpu_seconds_total{job="node",mode="idle"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_cpu_utilisation:rate5m"
    expression = <<-EOT
      1 - avg without (cpu) (  sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_load1_per_cpu:ratio"
    expression = <<-EOT
      (  node_load1{job="node"}/  instance:node_num_cpu:sum{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_memory_utilisation:ratio"
    expression = <<-EOT
      1 - (  (    node_memory_MemAvailable_bytes{job="node"}    or    (      node_memory_Buffers_bytes{job="node"}      +      node_memory_Cached_bytes{job="node"}      +      node_memory_MemFree_bytes{job="node"}      +      node_memory_Slab_bytes{job="node"}    )  )/  node_memory_MemTotal_bytes{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_vmstat_pgmajfault:rate5m"
    expression = <<-EOT
      rate(node_vmstat_pgmajfault{job="node"}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_weighted_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "kubernetes_recording_rules" {
  name                = "KubernetesRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Kubernetes Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate"
    expression = <<-EOT
      sum by (cluster, namespace, pod, container) (  irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (  1, max by(cluster, namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_working_set_bytes"
    expression = <<-EOT
      container_memory_working_set_bytes{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_rss"
    expression = <<-EOT
      container_memory_rss{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_cache"
    expression = <<-EOT
      container_memory_cache{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_swap"
    expression = <<-EOT
      container_memory_swap{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) ( (kube_pod_status_phase{phase=~"Pending|Running"} == 1) )
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    label_replace(      kube_pod_owner{job="kube-state-metrics", owner_kind="ReplicaSet"},      "replicaset", "$1", "owner_name", "(.*)"    ) * on(replicaset, namespace) group_left(owner_name) topk by(replicaset, namespace) (      1, max by (replicaset, namespace, owner_name) (        kube_replicaset_owner{job="kube-state-metrics"}      )    ),    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "deployment"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="DaemonSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "daemonset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="StatefulSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "statefulset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="Job"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "job"
    }
  }

  rule {
    enabled    = true
    record     = ":node_memory_MemAvailable_bytes:sum"
    expression = <<-EOT
      sum(  node_memory_MemAvailable_bytes{job="node"} or  (    node_memory_Buffers_bytes{job="node"} +    node_memory_Cached_bytes{job="node"} +    node_memory_MemFree_bytes{job="node"} +    node_memory_Slab_bytes{job="node"}  )) by (cluster)
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:node_cpu:ratio_rate5m"
    expression = <<-EOT
      sum(rate(node_cpu_seconds_total{job="node",mode!="idle",mode!="iowait",mode!="steal"}[5m])) by (cluster) /count(sum(node_cpu_seconds_total{job="node"}) by (cluster, instance, cpu)) by (cluster)
    EOT
  }
}
```
<!-- /tf:include -->

**`gateway-api.tf`** — enable Gateway API with AzAPI

<!-- tf:include path="terraform/05-aks/gateway-api.tf" -->
```hcl title="terraform/05-aks/gateway-api.tf"
# ---------------------------------------------------------------------------
# Enable Gateway API (the successor standard to Ingress)
#
# Background: community ingress-nginx maintenance ended in 2026-03, and Microsoft security patch support for the
#       AKS "application routing add-on (NGINX)" also ends in 2026-11. The successor is Gateway API,
#       and AKS offers two managed pieces:
#         1) Managed Gateway API CRDs        : AKS installs and upgrades CRDs such as Gateway/HTTPRoute
#         2) approuting-istio implementation : a sidecar-less Istio control plane turns Gateway resources into Envoy proxies
#
# azurerm_kubernetes_cluster in azurerm 5.9 does not expose this setting yet,
# so AzAPI applies it to the cluster as a "partial update".
# (Same approach as the official Microsoft Terraform sample 101-aks-application-routing-gateway-api)
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "gateway_api" {
  count = var.enable_gateway_api ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  # Runs after control_plane_metrics so that PUTs against the same cluster don't overlap.
  depends_on = [azapi_update_resource.control_plane_metrics]
}
```
<!-- /tf:include -->

**`access.tf`** — human access to the cluster (lab: the current user / team: an Entra group)

> [!TIP]
> By default, the "currently signed-in principal" that runs Terraform becomes the administrator (`grant_current_user_admin = true`). For teams and CI, run with `grant_current_user_admin = false` + `admin_principal_ids = ["<Entra group Object ID>"]` so that access doesn't shift when the principal running Terraform (a person or a pipeline) changes. If you leave both empty, the cluster would have no administrator, so a `validation` block prevents it.

<!-- tf:include path="terraform/05-aks/access.tf" -->
```hcl title="terraform/05-aks/access.tf"
locals {
  # Grants cluster admin permissions to the currently signed-in principal (grant_current_user_admin)
  # plus any additional principals you specify.
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

# ---------------------------------------------------------------------------
# Human access to the cluster = Azure RBAC role assignments
#   - Cluster User Role      : permission to fetch a kubeconfig with `az aks get-credentials` (ARM permission)
#   - RBAC Cluster Admin     : permission equivalent to cluster-admin on the Kubernetes API (data plane permission)
# Azure RBAC alone covers what EKS does with its "IAM principal → access entry → access policy" flow.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/outputs.tf" -->
```hcl title="terraform/05-aks/outputs.tf"
output "resource_group_name" {
  description = "Cluster resource group"
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  description = "Current control plane version (including patch)"
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "Resource group where AKS created the node VMSS, load balancer, etc."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer that Workload Identity federated credentials trust"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "available_kubernetes_versions" {
  description = "Kubernetes versions supported as GA in this region"
  value       = data.azurerm_kubernetes_service_versions.current.versions
}

output "get_credentials_command" {
  description = "Command that fetches the kubeconfig and converts it to Entra ID sign-in (kubelogin) format"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/tests/plan.tftest.hcl" -->
```hcl title="terraform/05-aks/tests/plan.tftest.hcl"
# Test the plan logic only, without Azure: terraform -chdir=terraform/05-aks test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "azapi" {}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "userAssignedNATGateway"
    error_message = "Outbound must use the BYO NAT Gateway."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "Local accounts (static kubeconfig) must be disabled."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 0
    error_message = "With the defaults, there must be no Spot pool."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 1
    error_message = "With the defaults, Gateway API must be enabled."
  }
}

run "plan_private_cluster_with_options" {
  command = plan

  variables {
    enable_private_cluster              = true
    enable_spot_pool                    = true
    enable_defender                     = true
    defender_log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-defender/providers/Microsoft.OperationalInsights/workspaces/law-defender"
    enable_gateway_api                  = false
    sku_tier                            = "Premium"
    admin_principal_ids                 = ["11111111-1111-1111-1111-111111111111"]
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 1
    error_message = "A Spot pool must be created."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 0
    error_message = "With enable_gateway_api=false, there must be no azapi update."
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 2
    error_message = "There must be 2 role assignments: 1 additional admin + the current user."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1
    error_message = "With the automatic grant to the current user turned off, only the 1 specified group must be an admin."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "rejects_malformed_version" {
  command = plan

  variables {
    kubernetes_version = "v1.36"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_defender_without_workspace" {
  command = plan

  variables {
    enable_defender = true
  }

  expect_failures = [azurerm_kubernetes_cluster.this]
}
```
<!-- /tf:include -->

## Walkthrough

### Step 1. Plan and apply

```bash
cd terraform/05-aks
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
```

What to check in the plan output:

- No `check.kubernetes_version_is_supported` warning appears (a warning lists the supported versions)
- The `network_profile`, `api_server_access_profile`, and `identity` values of `azurerm_kubernetes_cluster.this` connect to the results of Labs 03/04
- Resource count: 15 — resource group, cluster, User node pool, DCE 1 · DCR 2 · DCRA 2 (Prometheus / Container Insights), 2 Prometheus rule groups, diagnostic setting, 2 AzAPI updates, 2 role assignments

```bash
terraform apply tfplan        # cluster creation 10–20 min + azapi updates 5–10 min
```

> [!NOTE]
> During apply, `azapi_update_resource` updates the cluster one more time, so the total time gets longer. Use the wait to re-read *Design decisions*.

### Step 2. Get the kubeconfig (Entra ID sign-in)

```bash
eval "$(terraform output -raw get_credentials_command)"
# = az aks get-credentials ... && kubelogin convert-kubeconfig -l azurecli

kubectl get nodes -o wide
```

> [!NOTE]
> Use `eval "$(…)"`, not a bare `$(…)`. The output is a command line that contains `&&`, and a bare `$(…)` hands the `&&` to `az` as an argument, so it fails with `unrecognized arguments`.

> [!TIP]
> Local accounts are disabled, so the `--admin` option doesn't work. `kubectl` gets a token from your `az login` session, and your permissions come from the *Azure Kubernetes Service RBAC Cluster Admin* role granted in `access.tf` of Lab 05. Role propagation can take 1–5 minutes (if you get `Forbidden`, retry after a moment).
> Every `az aks get-credentials` makes that cluster the current `kubectl` context. Once you also have the Lab 10 cluster, check `kubectl config current-context` ([Appendix D](99-appendix.md)).

### Step 3. Verify

```bash
# Are the nodes spread across zones 1, 2, and 3, and split into System/User pools?
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/mode,agentpool

# System pods (Cilium, CoreDNS, ama-logs (container logs), ama-metrics (Prometheus), Azure Policy, etc.)
kubectl get pods -A -o wide | head -40

# Key cluster settings at a glance
az aks show -g "$(terraform output -raw resource_group_name)" -n "$(terraform output -raw cluster_name)" \
  --query "{version:currentKubernetesVersion, tier:sku.tier, localAccountsDisabled:disableLocalAccounts, aadRbac:aadProfile.enableAzureRbac, upgrade:autoUpgradeProfile, net:networkProfile.{plugin:networkPlugin, mode:networkPluginMode, dataplane:networkDataplane, policy:networkPolicy, outbound:outboundType}}" -o jsonc

# Permissions: do you have cluster-admin-equivalent permissions through Azure RBAC?
kubectl auth can-i '*' '*'

# Outbound: is the public IP that the internet sees for a pod the NAT Gateway from Lab 03?
kubectl run egress-test --rm -i --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- wget -qO- http://api.ipify.org
terraform -chdir=../03-network output -raw nat_gateway_public_ip

# Gateway API: are the CRDs and the GatewayClass (approuting-istio) ready?
kubectl get crd | grep gateway.networking.k8s.io
kubectl get gatewayclass
kubectl get pods -n aks-istio-system
```

Expected result: 6 or more nodes (`system` 3 + `user` 3), `kubectl auth can-i` → `yes`, `GatewayClass approuting-istio` shows `ACCEPTED True`, and the two outbound IPs are the same (egress goes through your NAT Gateway).

### Step 4. Check observability

![Observability pipeline: logs · metrics · control plane logs](diagrams/observability-pipeline.svg)

It takes 5–10 minutes for data to accumulate.

```bash
# Collection agent pods
kubectl get pods -n kube-system | grep -E "ama-logs|ama-metrics"

# Container Insights logs (KQL)
LAW_ID=$(az monitor log-analytics workspace show -g "$(az group list --query "[?ends_with(name,'-platform')].name | [0]" -o tsv)" \
  -n "$(az monitor log-analytics workspace list --query "[?starts_with(name,'log-')].name | [0]" -o tsv)" --query customerId -o tsv)
az monitor log-analytics query -w "$LAW_ID" --analytics-query "ContainerLogV2 | take 5 | project TimeGenerated, PodNamespace, LogMessage" -o table
az monitor log-analytics query -w "$LAW_ID" --analytics-query "AKSAuditAdmin | take 5 | project TimeGenerated, Verb, RequestUri" -o table
```

In Grafana (the `grafana_endpoint` from Lab 04), open **Dashboards → Azure Managed Prometheus → Kubernetes / Compute Resources / Cluster**. If node and pod CPU/memory show up, it's working.

## Advanced experiments

### (a) Add a Spot node pool

```bash
terraform apply -var enable_spot_pool=true
kubectl get nodes -L kubernetes.azure.com/scalesetpriority    # when a pod is scheduled, the node count grows from 0 → N
```

### (b) Switch to a fully private cluster

Run `terraform plan -var enable_private_cluster=true`. Changing `private_cluster_enabled` **recreates the cluster (forces replacement)**. In production, decide this from the start. With a private cluster, `kubectl` and the Terraform kubernetes provider can connect only from inside the VNet (VPN, Bastion, or a jump host). For an ad-hoc check, use `az aks command invoke`.

```bash
az aks command invoke -g <rg> -n <cluster> --command "kubectl get pods -A"
```

`command invoke` also works on the public cluster of this lab when you are on an address that is not in `allowed_ip_ranges`, such as Cloud Shell or another network ([Appendix D](99-appendix.md)).

### Automated verification script

A single `az aks show` call checks the cluster settings (security · networking · upgrades · add-ons · node pools), and `kubectl` checks the nodes, permissions, GatewayClass, and add-on pods.
It uses a temporary kubeconfig, so `~/.kube/config` isn't changed.

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 05-aks
```

<!-- tf:include path="scripts/verify/05-aks.sh" -->
```bash title="scripts/verify/05-aks.sh"
#!/usr/bin/env bash
# Lab 05 verification: checks that the AKS cluster was created as designed (read-only).
#   1) A single `az aks show` reads the cluster settings (the equivalent of aws eks describe-cluster)
#   2) kubectl checks nodes · permissions · add-ons. kubeconfig is a temporary file, so ~/.kube/config is left alone.
# Usage: scripts/verify.sh 05-aks
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready want zones gc pods p bad sku channel netrg podcidr nsgrules
  rg="$(tf_out 05-aks resource_group_name)"
  name="$(tf_out 05-aks cluster_name)"

  section "05-aks · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 05-aks?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  # --- Status ---
  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "Power state" "$(jv "$aks" .powerState.code)" "Running"
  sku="$(jv "$aks" .sku.tier)" # sku_tier variable: Free / Standard (default) / Premium
  case "$sku" in
    Standard | Premium) pass "SKU tier = $sku (includes uptime SLA)" ;;
    Free) warn "SKU tier = Free (no uptime SLA. Unless you changed sku_tier to cut costs, raise it to Standard)" ;;
    *) fail "SKU tier: expected Standard or Premium / actual '${sku:-(none)}'" ;;
  esac
  expect_set "Kubernetes version" "$(jv "$aks" .currentKubernetesVersion)"

  # --- Security / identity ---
  expect_eq "Local accounts (static kubeconfig) disabled" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Entra ID integration / Azure RBAC" "$(jv "$aks" '[.aadProfile.managed, .aadProfile.enableAzureRbac] | join("/")')" "true/true"
  expect_eq "OIDC issuer (prerequisite for Workload Identity)" "$(jv "$aks" .oidcIssuerProfile.enabled)" "true"
  expect_eq "Workload Identity" "$(jv "$aks" .securityProfile.workloadIdentity.enabled)" "true"

  # --- Networking ---
  expect_eq "CNI / mode" "$(jv "$aks" '[.networkProfile.networkPlugin, .networkProfile.networkPluginMode] | join("/")')" "azure/overlay"
  expect_eq "Data plane / network policy" "$(jv "$aks" '[.networkProfile.networkDataplane, .networkProfile.networkPolicy] | join("/")')" "cilium/cilium"
  expect_eq "Outbound type (your own NAT Gateway)" "$(jv "$aks" .networkProfile.outboundType)" "userAssignedNATGateway"
  # The 03-network node NSG allows inbound traffic between Pod CIDRs (the subnet NSG also applies to overlay Pod traffic).
  # If the two stacks' pod_cidr values differ, adding a Deny rule to the NSG later would block Pod-to-Pod
  # traffic between nodes (including DNS).
  netrg="$(tf_out 03-network resource_group_name)"
  podcidr="$(jv "$aks" .networkProfile.podCidr)"
  nsgrules=""
  [ -z "$netrg" ] || nsgrules="$(nodes_nsg_rules "$netrg")"
  if [ -z "$nsgrules" ]; then
    skip "Can't read the 03-network node NSG rules; skipping the Pod CIDR allow-rule check"
  else
    jq_ok "Node NSG allows inbound within the Pod CIDR ${podcidr} (pod_cidr is the same in 03-network and 05-aks)" "$nsgrules" \
      "any(.[]; .name == \"AllowPodsToPods\" and .access == \"Allow\" and .sourceAddressPrefix == \"$podcidr\" and .destinationAddressPrefix == \"$podcidr\")"
  fi
  expect_eq "API server VNet Integration" "$(jv "$aks" .apiServerAccessProfile.enableVnetIntegration)" "true"
  if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
    pass "Private cluster (API server reachable only from inside the VNet)"
  else
    jq_ok "API server authorized IP ranges set" "$aks" '(.apiServerAccessProfile.authorizedIpRanges | length) >= 1'
  fi

  # --- Upgrades / add-ons ---
  expect_eq "Node OS upgrade channel" "$(jv "$aks" .autoUpgradeProfile.nodeOsUpgradeChannel)" "NodeImage"
  channel="$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" # Default: patch. Other values are expected after Lab 09 approach A / C-1.
  case "$channel" in
    patch) pass "Auto-upgrade channel = patch (default setup)" ;;
    none | stable | rapid | node-image) pass "Auto-upgrade channel = $channel (changed from the default value patch - Lab 09)" ;;
    *) fail "Auto-upgrade channel: expected patch (or none/stable/rapid/node-image) / actual '${channel:-(none)}'" ;;
  esac
  jq_ok "Azure Policy add-on" "$aks" '.addonProfiles.azurepolicy.enabled == true'
  jq_ok "Container Insights (ama-logs)" "$aks" '.addonProfiles.omsagent.enabled == true or .azureMonitorProfile.containerInsights.enabled == true'
  jq_ok "Key Vault Secrets Store CSI driver" "$aks" '.addonProfiles.azureKeyvaultSecretsProvider.enabled == true'
  jq_ok "Managed Prometheus (ama-metrics)" "$aks" '.azureMonitorProfile.metrics.enabled == true'
  jq_ok "KEDA / VPA" "$aks" '.workloadAutoScalerProfile.keda.enabled == true and .workloadAutoScalerProfile.verticalPodAutoscaler.enabled == true'

  # --- Node pools ---
  jq_ok "System pool: autoscaling + ephemeral OS disk" "$aks" \
    '.agentPoolProfiles[] | select(.name == "system") | .mode == "System" and .enableAutoScaling == true and .osDiskType == "Ephemeral"'
  jq_ok "User pool: autoscaling" "$aks" \
    '.agentPoolProfiles[] | select(.name == "user") | .mode == "User" and .enableAutoScaling == true'
  expect_ge "System pool availability zone count" "$(jv "$aks" '.agentPoolProfiles[] | select(.name == "system") | .availabilityZones | length')" 2

  # --- kubectl ---
  section "05-aks · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the 'Azure Kubernetes Service Cluster User Role' role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
      skip "Can't reach the private cluster's API server; skipping kubectl checks (re-run from a jump host or VPN inside the VNet)"
    else
      fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply 05-aks."
    fi
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  # An autoscaled pool never goes below minCount, so the baseline is the sum of each pool's
  # minimum node count (default: system 3 + user 3).
  want="$(jv "$aks" '[.agentPoolProfiles[] | if .enableAutoScaling == true then (.minCount // 0) else (.count // 0) end] | add')"
  expect_ge "Ready nodes (sum of per-pool minimum node counts)" "$ready" "${want:-1}"
  zones="$(jv "$nodes" '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')"
  expect_ge "Availability zones the nodes are spread across" "$zones" 2

  if [ "$(kubectl --request-timeout=20s auth can-i '*' '*' 2>/dev/null)" = "yes" ]; then
    pass "cluster-admin permission (Azure RBAC Cluster Admin)"
  else
    fail "No cluster-admin permission (role propagation can take up to 5 min; check grant_current_user_admin / admin_principal_ids)"
  fi

  if [ "$(jv "$aks" '(.ingressProfile.gatewayApi // .ingressProfile.gatewayAPI // {}).installation')" = "Standard" ]; then
    gc="$(kj get gatewayclass approuting-istio)"
    jq_ok "GatewayClass approuting-istio is Accepted" "$gc" '.status.conditions[]? | select(.type == "Accepted") | .status == "True"'
  else
    skip "Gateway API is off; skipping the GatewayClass check (enable_gateway_api = false)"
  fi

  pods="$(kj get pods -n kube-system)"
  for p in ama-logs ama-metrics cilium coredns; do
    jq_ok "kube-system: $p pod Running" "$pods" "[.items[] | select((.metadata.name | startswith(\"$p\")) and .status.phase == \"Running\")] | length >= 1"
  done
  bad="$(kj get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded)"
  jq_warn "No pods other than Running/Completed" "$bad" '(.items | length) == 0'
}

# You can also run it directly (scripts/verify/05-aks.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

> [!TIP]
> If the kubectl step fails with "Couldn't reach the API server", it's almost always because your public IP changed (or you are on another network or in Cloud Shell). Update `TF_VAR_allowed_ip_ranges` and `apply` 05-aks again; the IP list is also used by `04-platform` and `10-aks-automatic` ([Appendix D](99-appendix.md)).
> Settings you changed from the default setup (`sku_tier`, `enable_gateway_api`, node counts, the Lab 09 upgrade channel) are shown as values, warnings, or skips instead of ✗. For a private cluster (`enable_private_cluster`), the script skips the kubectl step when you run it from outside the VNet.

## Common issues

| Symptom | Cause / Fix |
|---|---|
| `QuotaExceeded` / `Operation could not be completed as it results in exceeding approved ... cores` | Not enough vCPU quota → [step 4 of Lab 01](01-prerequisites.md). Reduce the size/count or request a quota increase. |
| `SkuNotAvailable`, `ZonalAllocationFailed` | The VM size is out of stock or restricted in that zone. Reduce `var.zones` to `["1","2"]` or change `*_node_vm_size`. |
| `AuthorizationFailed ... subnets/join/action` | Propagation delay, or a missing Network Contributor role from Lab 04. Retry after 5 minutes. |
| `Unable to connect to the server: ... i/o timeout` | Your public IP changed, or you are on another network or in Cloud Shell → update `TF_VAR_allowed_ip_ranges`, then run `terraform apply` (and see [Appendix D](99-appendix.md); `az aks command invoke` works meanwhile). |
| `error: You must be logged in to the server (Unauthorized)` | Run `az login` again, then `kubelogin convert-kubeconfig -l azurecli`. |
| `Forbidden: ... cannot list resource` | Wait for Azure RBAC role propagation (up to 5 minutes). Or, if you applied with `grant_current_user_admin = false`, check that your own (or your group's) Object ID is in `admin_principal_ids`. |
| A `default_node_pool.*` change in `terraform plan` requires replacing the node pool | Because `temporary_name_for_rotation` is set, the pool is replaced by **rotation**. System pods are briefly rescheduled during the replacement. |
| Prometheus is empty | Check the `ama-metrics` pod status and the DCRA association (`az monitor data-collection rule association list --resource <cluster-id>`). |

Next → [Lab 06. Workload Identity + Key Vault CSI](06-workload-identity.md)
