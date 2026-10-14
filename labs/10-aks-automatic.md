<!-- lang-switch -->
**English** | [한국어](ko/10-aks-automatic.md)
<!-- /lang-switch -->

# Lab 10. AKS Automatic: the "we operate it for you" mode, equivalent to EKS Auto Mode

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 30 min (apply 10–15 min) | AKS Standard tier + automatically provisioned nodes (delete right after the lab) | `terraform/10-aks-automatic` | [02. Remote state](02-bootstrap.md) (independent of Labs 03–05) |

> [!NOTE]
> As of 2026, Microsoft's Well-Architected guidance recommends the following: *"Choose AKS Automatic for most new production workloads, and choose Standard only when you need Windows nodes, LTS, or special network/platform customization."* This mode gives you **by default** what you designed yourself in Lab 05.

## What you build in this lab

What took about 250 lines of `cluster.tf` plus monitoring and network settings in Lab 05 takes about **20 lines** of resources here.

```text
 azurerm_kubernetes_automatic_cluster
  ├─ Managed system node pool (hosted and operated in AKS's own subscription)    ← You create it yourself in Standard
  ├─ Node Auto Provisioning (Karpenter-based) user nodes                         ← Automatically picks VMs that fit the pod requirements
  ├─ Azure CNI Overlay + Cilium, managed NAT Gateway
  ├─ Entra ID + Azure RBAC (no local accounts), Workload Identity/OIDC
  ├─ Deployment Safeguards + Pod Security Standards (baseline) enforce
  └─ approuting-istio (Gateway API implementation; CRDs included by default in 1.36+), Standard tier + Pod readiness SLA (99.9% / 5 min), automatic upgrades (stable, N-1)
```

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| EKS Auto Mode | **AKS Automatic** | In both, the cloud provider manages the nodes, scaling, upgrades, and main add-ons. |
| EC2 instances that Auto Mode creates (visible in your account) | **Managed system node pool** hosted in AKS's own subscription | The system nodes don't appear in your subscription's VM list. |
| Karpenter NodePool/EC2NodeClass | NAP's `NodePool` / `AKSNodeClass` CRDs | Same Karpenter-family API. |
| Configure Pod Security/Kyverno yourself | **Deployment Safeguards** (Azure Policy, enforce) | Deployments that violate rules such as resource requests/limits, probes, or the ban on `latest` tags are rejected. |
| You can modify EC2 instances directly in the account that manages the nodes | **Node resource group lock** (`MC_` can't be modified) | Prevents accidentally touching the nodes. |

## Standard vs. Automatic: which one to choose

![AKS Standard vs. AKS Automatic: who operates what](diagrams/standard-vs-automatic.svg)

| Area | AKS Automatic | AKS Standard (Lab 05) |
|---|---|---|
| System node pool | Managed (operated by AKS) | You create and operate it |
| Node scaling | **NAP only**, HPA/KEDA/VPA enabled | Choose Cluster Autoscaler or NAP |
| Tier / SLA | Standard + **Pod readiness SLA** + uptime SLA | Free (default) / Standard / Premium (LTS) |
| Upgrades | `stable` channel (N-1) + automatic node image updates | Manual or choose a channel |
| Authentication | Azure RBAC only (no local accounts) | Local accounts on by default → turning them off is recommended |
| Policy | Deployment Safeguards + PSS baseline **enforce** | Optional (Lab 08) |
| Networking | Overlay + Cilium, managed NAT, API server VNet Integration | Optional (you configure it yourself in Lab 03/05) |
| Observability | Prometheus/Container Insights on by default when created from the portal/CLI → **when you create it with Terraform, you connect them yourself** | You configure it yourself (the DCR pattern from Lab 05) |
| Constraints | No Windows nodes, some extensions unsupported (Dapr, etc.), **no conversion from Standard to Automatic** | Almost none |

> [!IMPORTANT]
> **Migrating from Standard to Automatic (in-place conversion) is not supported.** Decide up front which one you will use. If it's hard to decide, the recommended order is to start with Automatic and see what falls short.

## Design decisions (best practices)

| Decision | Why |
|---|---|
| Default to a **managed VNet** (`use_byo_network = false`) | Simplest option. If you need to integrate with an existing network or on-premises, you must start with a BYO VNet (it can't be changed afterward). |
| With BYO: 3 subnets (API server delegated /28, user nodes, system nodes) + **UAMI + Network Contributor on the VNet** | Same requirements as the official Microsoft sample. NAP creates nodes inside the VNet, so it needs permissions at the VNet scope. |
| `ignore_changes = [delegation]` on the system node subnet | After the cluster is created, AKS adds a delegation to the subnet; this prevents Terraform from trying to revert it. |
| Ingress: `web_app_routing_ingress { istio_enabled = true }` | Uses the approuting-istio implementation instead of NGINX. Only new Automatic clusters on 1.36+ include the Gateway API CRDs by default (the `stable` channel is N-1, so clusters are currently created on 1.35 and may not have the CRDs). |
| `api_server_access.authorized_ip_ranges` | Allow only your own IP on the public endpoint. |
| Admin permissions: `grant_current_user_admin` / `admin_principal_ids` | Automatic has no local accounts, so an Azure RBAC role is the only way to get access. In the lab, the role is granted to the signed-in user (default); for teams/CI, turn that off with `false` and set the Entra group Object ID in `admin_principal_ids` (if you leave both empty, `validation` blocks it). |

## Code

<!-- tf:include path="terraform/10-aks-automatic/versions.tf" -->
```hcl title="terraform/10-aks-automatic/versions.tf"
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
    key              = "10-aks-automatic.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/providers.tf" -->
```hcl title="terraform/10-aks-automatic/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/variables.tf" -->
```hcl title="terraform/10-aks-automatic/variables.tf"
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
  description = "Azure region (must be a region that supports AKS Automatic; koreacentral is supported)"
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
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default.
    In team/CI environments, set it to false and specify an Entra group in admin_principal_ids.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (AKS Automatic has no local accounts, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "use_byo_network" {
  description = <<-EOT
    false (default): "managed VNet" mode where AKS manages the VNet too - the simplest option.
    true           : use your own VNet/subnets (BYO VNet) - when you need to integrate with an existing network/on-premises.
  EOT
  type        = bool
  default     = false
}

variable "vnet_cidr" {
  description = "Address space of the VNet to create when use_byo_network = true"
  type        = string
  default     = "10.20.0.0/16"
}
```
<!-- /tf:include -->

**`main.tf`** — Resource group and (optional) BYO VNet

<!-- tf:include path="terraform/10-aks-automatic/main.tf" -->
```hcl title="terraform/10-aks-automatic/main.tf"
data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  byo = var.use_byo_network

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

resource "azurerm_resource_group" "automatic" {
  name     = module.naming.names.rg_automatic
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# (Optional) BYO VNet : created only when use_byo_network = true
# Same layout as the official Microsoft sample (101-aks-automatic-custom-network).
#   - API server subnet : delegated to Microsoft.ContainerService/managedClusters (/28 or larger)
#   - User node subnet  : where the nodes created by NAP are placed
#   - System node subnet: for the system node pool managed by AKS
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "byo" {
  count = local.byo ? 1 : 0

  name                = module.naming.names.vnet_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "api_server" {
  count = local.byo ? 1 : 0

  name                 = "snet-apiserver"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 12, 0)] # /28

  delegation {
    name = "aks-delegation"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "user_nodes" {
  count = local.byo ? 1 : 0

  name                 = "snet-user-nodes"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)] # /24
}

resource "azurerm_subnet" "system_nodes" {
  count = local.byo ? 1 : 0

  name                 = "snet-system-nodes"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 2)] # /24

  lifecycle {
    # After the cluster is created, AKS adds a delegation to this subnet.
    ignore_changes = [delegation]
  }
}

resource "azurerm_user_assigned_identity" "aks" {
  count = local.byo ? 1 : 0

  name                = module.naming.names.id_aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name
  tags                = local.tags
}

# Network Contributor so the cluster identity can join subnets and create NAP nodes inside the VNet
resource "azurerm_role_assignment" "network_contributor" {
  count = local.byo ? 1 : 0

  scope                = azurerm_virtual_network.byo[0].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[0].principal_id
  principal_type       = "ServicePrincipal"
}
```
<!-- /tf:include -->

**`cluster.tf`** — The Automatic cluster: compare it with `cluster.tf` from Lab 05.

<!-- tf:include path="terraform/10-aks-automatic/cluster.tf" -->
```hcl title="terraform/10-aks-automatic/cluster.tf"
# ---------------------------------------------------------------------------
# AKS Automatic  (the "we operate it for you" mode, equivalent to Amazon EKS Auto Mode)
#
# Most of the settings you configured by hand in 05-aks are "preconfigured" here, so the code is much shorter.
#   - Managed system node pool, Node Auto Provisioning (Karpenter-based) node autoscaling
#   - Azure CNI Overlay + Cilium, egress through a managed NAT Gateway
#   - Standard tier (uptime SLA) + Pod readiness SLA, auto upgrades (stable channel, N-1), automatic node image replacement
#   - Entra ID + Azure RBAC (no local accounts), Workload Identity/OIDC, Deployment Safeguards, image cleaner
#   - HPA / KEDA / VPA, node auto-repair, node resource group lockdown
#
# Note: Managed Prometheus / Container Insights are enabled by default only when you create the cluster with the
#       Azure CLI or the portal. This cluster, created with Terraform, is not connected to them, so connect them
#       yourself if you need them (as in 05-aks/monitoring.tf).
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_automatic_cluster" "this" {
  name                = module.naming.names.aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name

  # managed VNet: SystemAssigned is enough. BYO VNet: needs a UserAssigned identity that was granted permissions beforehand.
  identity {
    type         = local.byo ? "UserAssigned" : "SystemAssigned"
    identity_ids = local.byo ? [azurerm_user_assigned_identity.aks[0].id] : null
  }

  api_server_access {
    authorized_ip_ranges = var.allowed_ip_ranges
    subnet_id            = local.byo ? azurerm_subnet.api_server[0].id : null
  }

  dynamic "hosted_system" {
    for_each = local.byo ? [1] : []

    content {
      node_subnet_id        = azurerm_subnet.user_nodes[0].id
      system_node_subnet_id = azurerm_subnet.system_nodes[0].id
    }
  }

  # Ingress: Gateway API implementation (approuting-istio) instead of NGINX.
  # Same as the default for new Automatic clusters on AKS 1.36+.
  web_app_routing_ingress {
    istio_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.network_contributor]
}

# Automatic uses only Azure RBAC, so people need role assignments too.
# Grant them to the currently signed-in principal (grant_current_user_admin) and to the principals listed in
# admin_principal_ids (an Entra group is recommended in team environments).
locals {
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/outputs.tf" -->
```hcl title="terraform/10-aks-automatic/outputs.tf"
output "cluster_name" {
  description = "AKS Automatic cluster name"
  value       = azurerm_kubernetes_automatic_cluster.this.name
}

output "resource_group_name" {
  description = "Cluster resource group"
  value       = azurerm_resource_group.automatic.name
}

output "kubernetes_version" {
  description = "Current Kubernetes version (managed automatically by AKS through the stable channel)"
  value       = azurerm_kubernetes_automatic_cluster.this.current_kubernetes_version
}

output "get_credentials_command" {
  description = "Get the kubeconfig and convert it for kubelogin"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.automatic.name} --name ${azurerm_kubernetes_automatic_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/tests/plan.tftest.hcl" -->
```hcl title="terraform/10-aks-automatic/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/10-aks-automatic test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_managed_vnet" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.byo) == 0
    error_message = "The default (managed VNet) does not create a VNet."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1 && length(azurerm_role_assignment.cluster_user) == 1
    error_message = "With the automatic grant to the current user turned off, only the one specified group must be an admin."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "plan_byo_vnet" {
  command = plan

  variables {
    use_byo_network = true
  }

  assert {
    condition     = length(azurerm_subnet.api_server) == 1 && azurerm_subnet.api_server[0].address_prefixes[0] == "10.20.0.0/28"
    error_message = "The API server subnet must be a /28."
  }
}
```
<!-- /tf:include -->

## Walkthrough

### Step 1. Apply

```bash
cd terraform/10-aks-automatic
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
terraform apply tfplan            # 10–15 min
eval "$(terraform output -raw get_credentials_command)"
```

> [!NOTE]
> AKS Automatic turns on Azure Policy automatically. The `Microsoft.PolicyInsights` resource provider must be registered in the subscription ([Lab 01](01-prerequisites.md)).
> If the Azure CLI `aks-preview` extension is installed, it can conflict, so we recommend running `az extension remove -n aks-preview`.

> [!IMPORTANT]
> **You now have two clusters.** `az aks get-credentials` made this Automatic cluster the current `kubectl` context, so the commands in the next steps run against it. To go back to the Lab 05 cluster, use `kubectl config use-context <name>`; `kubectl config get-contexts` lists both, and `az aks list -o table` shows their SKUs (`Base` for Standard, `Automatic` for this one). See [Appendix D](99-appendix.md). This cluster is not connected to the Lab 04 ACR, so use public images here.

### Step 2. Inspect the cluster that has "no" nodes

```bash
kubectl get nodes              # At first there are few or no user nodes (you see 3 managed hostedpool nodes + 1 system-surge node)
kubectl get nodepools.karpenter.sh 2>/dev/null     # NAP NodePools (default, system-surge)
kubectl get gatewayclass       # approuting-istio (only on 1.36+ clusters that have the Gateway API CRDs)

# Outbound: AKS manages a NAT Gateway in the node resource group; its public IP is the cluster's egress IP
NODE_RG=$(az aks show -g "$(terraform output -raw resource_group_name)" -n "$(terraform output -raw cluster_name)" --query nodeResourceGroup -o tsv)
az network public-ip list -g "$NODE_RG" --query "[].ipAddress" -o tsv
```

> [!TIP]
> To see that address from inside the cluster, run the pod from [Appendix D](99-appendix.md) (D-2). A bare `kubectl run` pod is rejected here because it has no resource requests.

> [!NOTE]
> A new Automatic cluster is on the `stable` channel (N-1), so it is created with a version **one minor below the latest GA minor** (1.35.8 as of 2026-10), and `azurerm_kubernetes_automatic_cluster` doesn't let you pick the version. In this case `istio_enabled = true` turns on the approuting-istio implementation, but the Gateway API CRDs aren't installed, so `kubectl get gatewayclass` fails with `the server doesn't have a resource type "gatewayclass"` (this is expected). To use Gateway/HTTPRoute, check again after the cluster moves up to 1.36+.

### Step 3. Try Deployment Safeguards

A deployment that doesn't follow the safeguards is rejected (or triggers a warning).

```bash
kubectl create deployment naive --image=mcr.microsoft.com/dotnet/samples:aspnetapp --replicas=2
# → Deployment Safeguards violation messages appear (resource requests/limits, probes, etc.)
```

A deployment that follows best practices passes, and its pending pods prompt **NAP to create new nodes**.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: default }
spec:
  replicas: 3
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
      - name: hello
        image: mcr.microsoft.com/dotnet/samples:aspnetapp
        ports: [{ containerPort: 8080 }]
        resources:
          requests: { cpu: 500m, memory: 256Mi }
          limits:   { cpu: "1",  memory: 512Mi }
        readinessProbe: { httpGet: { path: /, port: 8080 } }
        livenessProbe:  { httpGet: { path: /, port: 8080 } }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1654
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
EOF

kubectl get pods -w                       # Pending → NAP provisions nodes → Running (usually 1–3 min)
kubectl get nodeclaims 2>/dev/null        # VMs requested by NAP (Karpenter NodeClaims)
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```

A VM size that fits the pod requirements (CPU/memory) is **selected automatically**. In Lab 05, this is the part where you chose the node pool's `vm_size` and `min/max` yourself.

### Step 4. (Optional) Try rebuilding with a BYO VNet

```bash
terraform destroy                                  # clean up the existing cluster (the VNet mode can't be switched after creation)
terraform apply -var use_byo_network=true          # VNet + 3 subnets + UAMI + role assignments + cluster
```

### Step 5. Clean up

```bash
kubectl delete deployment hello naive --ignore-not-found
terraform destroy
```

### Automated verification script

It checks the AKS Automatic settings (SKU, NAP, local accounts, upgrade channel) and the nodes/Karpenter NodePool (read-only).

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 10-aks-automatic
```

<!-- tf:include path="scripts/verify/10-aks-automatic.sh" -->
```bash title="scripts/verify/10-aks-automatic.sh"
#!/usr/bin/env bash
# Lab 10 verification: checks that the AKS Automatic cluster was created in the "we operate it for you" mode (read-only).
#   AWS comparison: EKS Auto Mode (the cloud manages nodes · scaling · upgrades · security defaults)
# Usage: scripts/verify.sh 10-aks-automatic
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready pools
  rg="$(tf_out 10-aks-automatic resource_group_name)"
  name="$(tf_out 10-aks-automatic cluster_name)"

  section "10-aks-automatic · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 10-aks-automatic?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "SKU (name / tier)" "$(jv "$aks" '[.sku.name, .sku.tier] | join("/")')" "Automatic/Standard"
  expect_eq "Node provisioning (NAP = Karpenter-based)" "$(jv "$aks" .nodeProvisioningProfile.mode)" "Auto"
  expect_eq "Local accounts disabled (Azure RBAC only)" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Azure RBAC" "$(jv "$aks" .aadProfile.enableAzureRbac)" "true"
  expect_eq "CNI / data plane" "$(jv "$aks" '[.networkProfile.networkPluginMode, .networkProfile.networkDataplane] | join("/")')" "overlay/cilium"
  expect_eq "Auto-upgrade channel" "$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" "stable"
  expect_eq "OIDC issuer / Workload Identity" "$(jv "$aks" '[.oidcIssuerProfile.enabled, .securityProfile.workloadIdentity.enabled] | join("/")')" "true/true"

  section "10-aks-automatic · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply."
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  expect_ge "Ready nodes (managed system pool)" "$ready" 1

  # NAP creates nodes through Karpenter NodePools (the same concept as NodePools in EKS Auto Mode).
  pools="$(kj get nodepools.karpenter.sh)"
  jq_warn "Karpenter NodePool exists (NAP)" "$pools" '(.items | length) >= 1'
}

# You can also run it directly (scripts/verify/10-aks-automatic.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## Common issues

| Symptom | Cause / Fix |
|---|---|
| `Location is not supported` | Check that the region supports Automatic (`koreacentral`, `koreasouth`, and others are supported). |
| `MissingSubscriptionRegistration ... PolicyInsights` | `az provider register -n Microsoft.PolicyInsights`. |
| Pods stay `Pending` | Not enough vCPU quota (NAP picks the VM family automatically). Check the quota and request an increase; also check `kubectl describe pod` and `kubectl get nodeclaims`. |
| `Forbidden` (kubectl) | Wait for the Azure RBAC role to propagate (up to 5 min). Automatic has no local accounts. If `grant_current_user_admin = false`, check that you (or a group you belong to) are listed in `admin_principal_ids`. |
| `LinkedAuthorizationFailed` with BYO | The UAMI's Network Contributor role is still propagating → retry. |

Next → [Lab 11. Cleanup](11-cleanup.md)
