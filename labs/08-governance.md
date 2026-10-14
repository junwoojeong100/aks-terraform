<!-- lang-switch -->
**English** | [한국어](ko/08-governance.md)
<!-- /lang-switch -->

# Lab 08. Governance and security: Azure Policy · Defender · locks · budgets

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 30 min (including the wait for policy sync) | Free in the default configuration. The Defender plan is billed per vCore (optional) | `terraform/08-governance` | [05. AKS cluster](05-aks.md) |

## What you build in this lab

![Where to apply governance: scopes](diagrams/governance-scopes.svg)

| Layer | Resource | Effect |
|---|---|---|
| **Cluster configuration checks** | 6 built-in policies (local account blocking, authorized IP ranges, RBAC, managed identity, Policy add-on, Defender profile) | **Audit** whether the cluster meets best practices |
| **In-cluster (admission) checks** | Pod security initiatives `baseline` and `restricted` | `Audit` or `Deny` for things like running as non-root, no privilege escalation, and resource limits |
| **Threat detection** | `azurerm_security_center_subscription_pricing` (Defender for Containers) | Runtime threats, image vulnerabilities, misconfigurations (optional) |
| **Deletion protection** | `azurerm_management_lock` | Prevents accidental deletion of the network/platform resource groups (optional) |
| **Cost guardrail** | `azurerm_consumption_budget_subscription` | Monthly budget alerts filtered by the `workload` tag (optional) |

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| SCP (organization permission ceiling) | **Azure Policy** (+ RBAC `deny assignments`) | An SCP is an "IAM permission ceiling"; Azure Policy evaluates *resource properties and request content* and audits, denies, or modifies. |
| AWS Config rules / Conformance pack | **Policy definitions / initiatives (policySet)** + compliance state | An initiative is the equivalent of a conformance pack. There are a great many built-in definitions. |
| Kyverno / OPA Gatekeeper | **Azure Policy for Kubernetes** (add-on based on Gatekeeper v3) | Assign it with the same `azurerm_resource_group_policy_assignment` and it is synced to the cluster as Gatekeeper Constraints. |
| GuardDuty (EKS) / Inspector (ECR) / Security Hub | **Microsoft Defender for Containers** + Defender for Cloud | A subscription-level plan + the cluster's `microsoft_defender` profile. |
| CloudFormation Termination Protection / SCP deny | **Resource locks (CanNotDelete / ReadOnly)** | A lock blocks *deletion itself* (even for owners). You must remove it before `terraform destroy`. |
| AWS Budgets | **Cost Management budgets** | Email / action group notifications. Track per workload with a tag filter. |

## Design decisions (best practices)

| Decision | Why |
|---|---|
| **Roll out in phases: Audit → Deny** (`policy_effect`) | If you enable Deny from the start, existing workloads get blocked. Review the audit results, sort out the exceptions, and only then raise it to Deny. |
| Assignment scope = **the cluster resource group** | Keeps the lab scope limited. In production, raise it to a management group or subscription so that every cluster inherits it. |
| System namespaces in `excludedNamespaces` | Namespaces that AKS manages, such as `kube-system`, `gatekeeper-system`, and `aks-istio-system`, are excluded from evaluation. |
| The `restricted` initiative is always Audit | It shows "how close you are to the next level (a stricter standard)." |
| Policy definitions/GUIDs are spelled out in the code | Built-in definition IDs are the same worldwide. You can always verify them with `az policy definition show --name <GUID>`. |
| Subscription-level Defender plan / locks / budgets are **off by default** | They affect the whole subscription, cost money, or get in the way of deletion, so you turn them on explicitly. |

> [!NOTE]
> In **AKS Automatic**, many of the policies above are applied by default in **enforce mode**, through *Deployment Safeguards* and *Pod Security Standards (baseline)* → [Lab 10](10-aks-automatic.md).

## Code

<!-- tf:include path="terraform/08-governance/versions.tf" -->
```hcl title="terraform/08-governance/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "08-governance.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/providers.tf" -->
```hcl title="terraform/08-governance/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {}
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/variables.tf" -->
```hcl title="terraform/08-governance/variables.tf"
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

variable "policy_effect" {
  description = <<-EOT
    Effect of the pod security initiatives (baseline/restricted).
    Audit = only record violations (lab default), Deny = block creation of violating resources.
    Turn on Deny only after you have confirmed that the workloads you plan to deploy to the cluster satisfy the policy.
  EOT
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.policy_effect)
    error_message = "policy_effect must be one of Audit, Deny, or Disabled."
  }
}

variable "enable_defender_plan" {
  description = <<-EOT
    Enable the subscription-level Microsoft Defender for Containers plan.
    It affects the whole subscription and is billed per vCore, so the default is false.
  EOT
  type        = bool
  default     = false
}

variable "enable_resource_locks" {
  description = "Set a CanNotDelete lock on the network/platform resource groups (you must remove it before cleaning up the lab)."
  type        = bool
  default     = false
}

variable "enable_budget" {
  description = "Create a monthly budget alert based on the workload tag (requires budget_alert_emails)"
  type        = bool
  default     = false
}

variable "budget_amount" {
  description = "Monthly budget amount (in the subscription's billing currency)"
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "List of email addresses to receive budget alerts"
  type        = list(string)
  default     = []
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/main.tf" -->
```hcl title="terraform/08-governance/main.tf"
data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

data "azurerm_resource_group" "aks" {
  name = module.naming.names.rg_aks
}

data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_resource_group" "platform" {
  name = module.naming.names.rg_platform
}
```
<!-- /tf:include -->

**`policy.tf`** — Azure Policy assignments

<!-- tf:include path="terraform/08-governance/policy.tf" -->
```hcl title="terraform/08-governance/policy.tf"
# ---------------------------------------------------------------------------
# Azure Policy for AKS  (combines the roles of AWS Config rules + SCPs + Kyverno/Gatekeeper)
#
#   - Checks on cluster "configuration": ARM-level policies (e.g. block local accounts, authorized IP ranges)
#                                        → similar to AWS Config rules
#   - Checks "inside" the cluster      : the Azure Policy add-on (Gatekeeper) evaluates at Kubernetes admission
#                                        → similar to Kyverno/OPA
#
# The assignment scope is the resource group that contains the cluster. Assigning at the subscription or
# management group level makes every cluster inherit the policies.
# ---------------------------------------------------------------------------
locals {
  # System namespaces to exclude from policy evaluation (initiative defaults + AKS managed add-ons)
  policy_excluded_namespaces = [
    "kube-system",
    "gatekeeper-system",
    "azure-arc",
    "azure-extensions-usage-system",
    "aks-istio-system",
    "app-routing-system",
  ]

  # Built-in policy initiatives (policySet): Pod Security Standards (Linux)
  pod_security_initiatives = {
    baseline = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
      display_name = "AKS pod security baseline (Linux)"
    }
    restricted = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
      display_name = "AKS pod security restricted (Linux)"
    }
  }

  # Built-in policy definitions: cluster configuration checks (all Audit-only)
  cluster_config_policies = {
    local-auth-disabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9eb0-df2c3a730c32"
      display_name = "AKS clusters should have local authentication methods disabled"
    }
    policy-addon-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0a15ec92-a229-4763-bb14-0ea34a568f8d"
      display_name = "The Azure Policy add-on should be installed on AKS clusters"
    }
    rbac-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/ac4a19c2-fa67-49b4-8ae5-0b2e78c49457"
      display_name = "Kubernetes RBAC should be used"
    }
    authorized-ip-ranges = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0e246bcf-5f6f-4f87-bc6f-775d4712c7ea"
      display_name = "API server authorized IP ranges should be defined"
    }
    managed-identity = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/da6e2401-19da-4532-9141-fb8fbde08431"
      display_name = "AKS clusters should use a managed identity"
    }
    defender-profile = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/a1840de2-8088-4ea8-b153-b4c723e9cb01"
      display_name = "AKS clusters should have the Defender profile enabled"
    }
  }
}

resource "azurerm_resource_group_policy_assignment" "pod_security" {
  for_each = local.pod_security_initiatives

  name                 = "aks-pod-security-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id

  # Only baseline follows var.policy_effect; restricted always stays Audit to show the "readiness for the next step".
  parameters = jsonencode({
    effect = {
      value = each.key == "baseline" ? var.policy_effect : "Audit"
    }
    excludedNamespaces = {
      value = local.policy_excluded_namespaces
    }
  })

  non_compliance_message {
    content = "This violates the pod security standards. Check non-root execution, privilege escalation, resource limits, etc."
  }
}

resource "azurerm_resource_group_policy_assignment" "cluster_config" {
  for_each = local.cluster_config_policies

  name                 = "aks-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id
}
```
<!-- /tf:include -->

**`security.tf`** — Defender plan, resource locks

<!-- tf:include path="terraform/08-governance/security.tf" -->
```hcl title="terraform/08-governance/security.tf"
# ---------------------------------------------------------------------------
# Microsoft Defender for Containers  (equivalent to GuardDuty EKS Protection + Inspector (ECR scanning) + Security Hub)
#   - Turning on the subscription-level "plan" works together with the cluster-level microsoft_defender profile
#     (05-aks: enable_defender + defender_log_analytics_workspace_id).
#   - Features: runtime threat detection, ACR image vulnerability scanning,
#     misconfiguration (Kubernetes security posture) assessment
# ---------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  count = var.enable_defender_plan ? 1 : 0

  resource_type = "Containers"
  tier          = "Standard"
}

# ---------------------------------------------------------------------------
# Resource locks (similar to CloudFormation stack policies / Termination Protection)
# ---------------------------------------------------------------------------
resource "azurerm_management_lock" "network" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.network.id
  lock_level = "CanNotDelete"
  notes      = "The network is shared by several stacks, so this lock prevents accidental deletion."
}

resource "azurerm_management_lock" "platform" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.platform.id
  lock_level = "CanNotDelete"
  notes      = "Protects the shared ACR / Key Vault / monitoring services"
}
```
<!-- /tf:include -->

**`budget.tf`** — Budget alerts

<!-- tf:include path="terraform/08-governance/budget.tf" -->
```hcl title="terraform/08-governance/budget.tf"
# ---------------------------------------------------------------------------
# Budget alerts (equivalent to AWS Budgets)
# Tracks only the cost of resources whose workload tag matches, across the whole subscription. Resources in the
# AKS node resource group inherit the cluster tags, so they are counted too.
# ---------------------------------------------------------------------------
resource "time_static" "budget_start" {}

locals {
  # The budget start date must be "00:00Z on the 1st of the current month". It is pinned to the month of the first creation.
  budget_start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", time_static.budget_start.rfc3339)
}

resource "azurerm_consumption_budget_subscription" "workload" {
  count = var.enable_budget ? 1 : 0

  name            = "budget-${module.naming.base}"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  filter {
    tag {
      name   = "workload"
      values = [var.workload]
    }
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  lifecycle {
    precondition {
      condition     = length(var.budget_alert_emails) > 0
      error_message = "If enable_budget = true, specify at least one email address in budget_alert_emails."
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/outputs.tf" -->
```hcl title="terraform/08-governance/outputs.tf"
output "policy_assignments" {
  description = "Names of the policies assigned to the cluster resource group"
  value = concat(
    [for a in azurerm_resource_group_policy_assignment.pod_security : a.name],
    [for a in azurerm_resource_group_policy_assignment.cluster_config : a.name],
  )
}

output "compliance_command" {
  description = "Query the policy compliance state (the initial evaluation can take up to tens of minutes after assignment)"
  value       = "az policy state summarize --resource-group ${module.naming.names.rg_aks}"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/tests/plan.tftest.hcl" -->
```hcl title="terraform/08-governance/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/08-governance test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "time" {}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_security_center_subscription_pricing.containers) == 0
    error_message = "The subscription-level Defender plan is not enabled by default."
  }

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.pod_security) == 2
    error_message = "Two initiatives, baseline and restricted, must be assigned."
  }
}

run "plan_everything_enabled" {
  command = plan

  variables {
    enable_defender_plan  = true
    enable_resource_locks = true
    enable_budget         = true
    budget_alert_emails   = ["ops@example.com"]
    policy_effect         = "Deny"
  }

  assert {
    condition     = length(azurerm_management_lock.network) == 1 && length(azurerm_consumption_budget_subscription.workload) == 1
    error_message = "The lock and the budget must be created."
  }
}

run "budget_requires_email" {
  command = plan

  variables {
    enable_budget = true
  }

  expect_failures = [azurerm_consumption_budget_subscription.workload]
}
```
<!-- /tf:include -->

## Walkthrough

### Step 1. Apply the default (Audit) configuration

```bash
cd terraform/08-governance
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # 8 policy assignments + 1 time_static for the budget start date = 9 to add
terraform apply tfplan
```

### Step 2. Check that the policies synced to the cluster

The Azure Policy add-on syncs assignments about every 15 minutes. The first sync takes a while.

```bash
# Were Gatekeeper Constraints created in the cluster?
kubectl get constrainttemplates | head
kubectl get constraints | head -20

# Compliance summary (evaluation can take up to tens of minutes)
$(terraform output -raw compliance_command)
az policy state list -g "$(terraform -chdir=../05-aks output -raw resource_group_name)" \
  --filter "complianceState eq 'NonCompliant'" --query "[].{policy:policyDefinitionName, resource:resourceId}" -o table
```

Expected result: in the default configuration, policies such as `authorized-ip-ranges` (✓) and `local-auth-disabled` (✓) show as **Compliant**, while the Defender profile policy shows as **NonCompliant** because `enable_defender=false` → the audit is working as intended.

> [!NOTE]
> If the subscription already has a *Defender for Containers auto-provisioning* policy (the default in subscriptions where Defender is on), that policy attaches the Defender profile to the cluster directly, using the subscription's default Defender workspace. In that case the Defender profile policy is Compliant from the start, and the `plan` for 05-aks keeps showing a diff that removes `microsoft_defender`. To make Terraform declare the same profile, follow step 4 and reuse the workspace that the profile already uses. Do **not** point it at the platform workspace from Lab 04: that workspace disables local authentication, which the Defender sensor does not support, and its `microsoft-defender-publisher` pods crash-loop. The evaluation results also include non-compliant items from subscription-level initiatives (e.g., the ASC default initiative).

### Step 3. Try the Deny effect

```bash
terraform apply -var policy_effect=Deny      # wait about 15 min for the add-on to sync

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: bad-pod, namespace: default }
spec:
  containers:
  - name: bad
    image: mcr.microsoft.com/cbl-mariner/busybox:2.0
    command: ["sleep","3600"]
    securityContext: { privileged: true }
EOF
# → admission webhook "validation.gatekeeper.sh" denied the request: ... Privileged container is not allowed
```

> [!NOTE]
> Create the test pod in the **`default`** namespace, not `web`. The `web` namespace has Pod Security Standards (`baseline` enforce) applied, so the same pod is rejected with `violates PodSecurity "baseline:latest": privileged` before Azure Policy (Gatekeeper) can evaluate it. Both are rejections, but what you want to see in this step is the Azure Policy Deny effect.

When you're done, revert with `terraform apply` (default Audit). While Deny is on, the apps you deployed in Labs 06 and 07 must also satisfy the policy (the apps in this guide are written to do so).

### Step 4. (Optional) Defender / budget / locks

```bash
# Defender for Containers: subscription-level plan
terraform apply -var enable_defender_plan=true
az security pricing show -n Containers --query pricingTier -o tsv     # Standard

# Defender profile on the cluster. The Defender sensor needs a Log Analytics workspace that allows local
# authentication, so the platform workspace from Lab 04 cannot be used. If the policy already attached the
# profile, reuse its workspace (the second command fixes the letter case that AKS returns, which azurerm rejects).
# The first apply only changes the letter case of the ID; repeat both -var flags on later applies of 05-aks,
# otherwise the plan shows the removal diff again.
RAW=$(az aks show -g "$(terraform -chdir=../05-aks output -raw resource_group_name)" -n "$(terraform -chdir=../05-aks output -raw cluster_name)" \
  --query securityProfile.defender.logAnalyticsWorkspaceResourceId -o tsv)
WS=$(az monitor log-analytics workspace show --ids "$RAW" --query id -o tsv)
terraform -chdir=../05-aks apply -var enable_defender=true -var defender_log_analytics_workspace_id="$WS"
kubectl -n kube-system get pods | grep microsoft-defender             # all Running, including the publisher pods

# Monthly budget alerts (email)
terraform apply -var enable_budget=true -var 'budget_alert_emails=["you@example.com"]' -var budget_amount=150

# Deletion-protection locks
terraform apply -var enable_resource_locks=true
az group delete -n "$(terraform -chdir=../03-network output -raw resource_group_name)" --yes   # → should fail with ScopeLocked (expected)
```

> [!WARNING]
> If you clean up while the locks (`enable_resource_locks`) are still on, `terraform destroy` fails. **Destroy just the lock resources first, before cleaning up**: `terraform destroy -target=azurerm_management_lock.network -target=azurerm_management_lock.platform` (run in this stack). `scripts/cleanup.sh` does this automatically → [Lab 11](11-cleanup.md).

### Automated verification script

It checks the policy assignments and compliance state, the Defender plan, and the resource locks. When the policy effect is the default `Audit`, non-compliant resources are shown only as a **warning (!)** (evaluation can take up to tens of minutes right after assignment).

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 08-governance
```

<!-- tf:include path="scripts/verify/08-governance.sh" -->
```bash title="scripts/verify/08-governance.sh"
#!/usr/bin/env bash
# Lab 08 verification: checks Azure Policy assignments · compliance state · Defender · resource locks (read-only).
#   AWS comparison: AWS Config/SCP + Security Hub/GuardDuty + resource deletion protection (termination protection)
#   Policies default to Audit (report only), so non-compliant resources are shown only as a "warning".
# Usage: scripts/verify.sh 08-governance
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg names n a state tier g count
  rg="$(tf_out 05-aks resource_group_name)"
  names="$(terraform -chdir="${TF_DIR}/08-governance" output -json policy_assignments 2>/dev/null | jq -r '.[]?' 2>/dev/null)"

  section "08-governance · policy assignments (${rg:-?})"
  if [ -z "$names" ]; then
    fail "Can't read the policy_assignments output. Did you finish init/apply in 08-governance?"
    return
  fi
  for n in $names; do
    a="$(azj policy assignment show -n "$n" -g "$rg")"
    expect_set "Policy assignment $n" "$(jv "$a" .displayName)"
  done

  # Compliance evaluation can take up to tens of minutes right after assignment.
  # Even with non-compliant resources, Audit mode doesn't block deployments.
  state="$(azj policy state summarize -g "$rg")"
  if [ -z "$state" ]; then
    warn "Can't query the compliance state yet (right after assignment, evaluation may not have run)"
  else
    jq_warn "No non-compliant resources (currently $(jv "$state" '.results.nonCompliantResources // 0'))" "$state" '(.results.nonCompliantResources // 0) == 0'
  fi

  section "08-governance · Defender · locks"
  tier="$(az security pricing show -n Containers --query pricingTier -o tsv 2>/dev/null)"
  if [ "$tier" = "Standard" ]; then
    pass "Defender for Containers subscription plan is on"
  else
    info "Defender for Containers subscription plan: ${tier:-unknown} (default: enable_defender_plan = false)"
  fi
  for g in "$(tf_out 03-network resource_group_name)" "$(tf_out 04-platform resource_group_name)"; do
    [ -n "$g" ] || continue
    count="$(az lock list -g "$g" --query 'length(@)' -o tsv 2>/dev/null)"
    info "Resource locks in $g: ${count:-0} (default: enable_resource_locks = false)"
  done
}

# You can also run it directly (scripts/verify/08-governance.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## Common issues

| Symptom | Cause / Fix |
|---|---|
| `AuthorizationFailed ... policyAssignments/write` | Missing permission to assign policies (Resource Policy Contributor/Owner). |
| `kubectl get constraints` returns nothing | The add-on is still syncing (up to 15 min). Check the pod status with `kubectl get pods -n kube-system \| grep azure-policy` and `kubectl get pods -n gatekeeper-system`, and verify that `azure_policy_enabled = true`. |
| Compliance state stays at `NotStarted` | The first evaluation is slow (tens of minutes). You can request a manual evaluation with `az policy state trigger-scan -g <rg>`. |
| Budget creation error `start_date` | The budget start date must be the **first day of the current month** (the code computes it automatically with `time_static`). |
| Cost goes up after enabling the Defender plan | You are billed for the vCores of all AKS nodes in the subscription. Turn it off after the lab with `-var enable_defender_plan=false`. |

Next → [Lab 09. Day-2 operations: upgrades · scaling · node replacement · testing](09-operations.md)
