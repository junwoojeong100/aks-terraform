<!-- lang-switch -->
**English** | [한국어](ko/06-workload-identity.md)
<!-- /lang-switch -->

# Lab 06. Workload Identity + Key Vault CSI: the Azure version of IRSA

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 25 min | Almost none (1 pod) | `terraform/06-workload` | [05. AKS cluster](05-aks.md) |

## What you build in this lab

This is the complete flow for a pod to read a Key Vault secret **without any static credentials (keys or passwords)**.

![Workload Identity flow (compared with IRSA)](diagrams/workload-identity-flow.svg)

Here is the Azure side of the flow, step by step:

```text
 Pod  (ServiceAccount: demo/workload-sa, label azure.workload.identity/use=true)
  │ ① kubelet mounts the SA token into the pod as a projected token
  │    iss = cluster OIDC issuer,  sub = system:serviceaccount:demo:workload-sa,  aud = api://AzureADTokenExchange
  ▼
 Microsoft Entra ID ── ② finds the UAMI whose federated credential (issuer + subject) matches ──► ③ issues an Entra access token
  ▼
 Key Vault  ── RBAC: "Key Vault Secrets User" granted to that UAMI ──► CSI driver mounts it at /mnt/secrets-store/demo-secret
```

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| IAM OIDC Provider (registered per cluster) | Cluster **OIDC issuer** (`oidc_issuer_enabled`) | No separate registration is needed. You get the issuer URL from the `oidc_issuer_url` output. |
| IAM Role + trust policy (`sub` condition) | **UAMI + federated identity credential** (`issuer`, `subject`, `audience`) | An `azurerm_federated_identity_credential` resource replaces the trust policy JSON. |
| ServiceAccount annotation `eks.amazonaws.com/role-arn` | Annotation `azure.workload.identity/client-id` | The pod also needs the label `azure.workload.identity/use: "true"`. |
| IAM Policy (secretsmanager:GetSecretValue) | Role assignment **Key Vault Secrets User** (data plane) | Management plane roles such as `Contributor` cannot read secret values. |
| Secrets Manager + CSI provider | **Key Vault provider for Secrets Store CSI Driver** (AKS add-on) | You declare the objects to fetch with the `SecretProviderClass` CRD. Supports an automatic refresh interval (`secret_rotation_interval`). |
| EKS Pod Identity (association API) | (no equivalent) → *Identity bindings for AKS* | A UAMI is limited to **20 federated credentials**, so consider Identity bindings when several clusters share one identity. |

> [!IMPORTANT]
> You can attach **at most 20** federated credentials to a single UAMI. If you design for "one UAMI per app (namespace/SA)" by default, you rarely hit the limit and permissions stay minimal.

## Design decisions (best practices)

| Decision | Why |
|---|---|
| **Kubernetes resources in a separate stack (06)**, applied once the cluster already exists | Using the `kubernetes` provider in the same stack that creates the cluster means the provider configuration is only resolved at apply time, which makes planning and deletion error-prone. |
| `kubernetes` provider authentication = **kubelogin + Azure CLI token** | Local accounts are disabled, so there are no static certificates or tokens. It is the same pattern as the `aws eks get-token` exec plugin for EKS. |
| A dedicated UAMI for the app, granted only **Secrets User (read)** | Least privilege. Only humans (Secrets Officer) can write. |
| The secret value is **ephemeral + write-only (`value_wo`)** | The value is never stored in the Terraform state (write-only arguments need Terraform 1.11+ and are supported in azurerm 5.x). To change the value, bump `value_wo_version`. |
| **Pod Security `restricted`** enforced on the namespace | Enforces baseline security (non-root, no privilege escalation, seccomp, etc.) at the namespace level. |
| `time_sleep` to wait for RBAC propagation | Prevents the common failure where a data plane call returns 403 right after a role assignment. `depends_on` makes both secret creation (operator permissions) and the pod's secret mount (app permissions + federated credential) run only after this wait. |

## Code

<!-- tf:include path="terraform/06-workload/versions.tf" -->
```hcl title="terraform/06-workload/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "06-workload.tfstate"
  }
}
```
<!-- /tf:include -->

**`providers.tf`** — the key part is how the `kubernetes` provider connects through kubelogin.

<!-- tf:include path="terraform/06-workload/providers.tf" -->
```hcl title="terraform/06-workload/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ---------------------------------------------------------------------------
# kubernetes provider → connects to the cluster created by 05-aks
#   - This stack runs separately, after the cluster "already exists", so the provider configuration does not depend
#     on resources that are only known at apply time (avoids the common problem of using the kubernetes provider
#     in the same stack that creates the cluster).
#   - Local accounts are disabled, so instead of a static certificate, kubelogin gets a token from the Azure CLI login.
#     (Same approach as the `aws eks get-token` exec plugin on EKS. server-id is the fixed Entra server app ID of AKS.)
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/06-workload/variables.tf" -->
```hcl title="terraform/06-workload/variables.tf"
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

variable "app_namespace" {
  description = "Kubernetes namespace to deploy the demo app into"
  type        = string
  default     = "demo"
}

variable "app_service_account" {
  description = "Name of the Kubernetes ServiceAccount to link with Workload Identity"
  type        = string
  default     = "workload-sa"
}

variable "app_image" {
  description = <<-EOT
    Demo container image. If left empty, <acr>.azurecr.io/demo/busybox:2.0 is used.
    Import it into ACR beforehand with `az acr import` (see Lab 06).
  EOT
  type        = string
  default     = ""
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/06-workload/main.tf" -->
```hcl title="terraform/06-workload/main.tf"
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

  app_name = "kv-demo"
  app_image = (
    var.app_image != "" ? var.app_image : "${data.azurerm_container_registry.this.login_server}/demo/busybox:2.0"
  )
}

# Look up the resources created by earlier stacks by naming convention
data "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  resource_group_name = module.naming.names.rg_aks
}

data "azurerm_key_vault" "this" {
  name                = module.naming.names.key_vault
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  resource_group_name = module.naming.names.rg_platform
}

resource "azurerm_resource_group" "workload" {
  name     = module.naming.names.rg_workload
  location = var.location
  tags     = local.tags
}
```
<!-- /tf:include -->

**`identity.tf`** — Azure side: UAMI, federated credential, role assignments, secret

<!-- tf:include path="terraform/06-workload/identity.tf" -->
```hcl title="terraform/06-workload/identity.tf"
# ---------------------------------------------------------------------------
# Azure side: app-specific managed identity + federated credential + least privilege
#
# Mapping to IRSA
#   AWS  : IAM Role + OIDC Provider (per cluster) + trust policy (sub condition) + SA annotation (role-arn)
#   Azure: UAMI + Federated credential (issuer + subject) + SA annotation (client-id) + pod label
# Both approaches exchange a "Kubernetes SA token → temporary cloud credentials", so no static keys are needed.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.app_name}-${module.naming.base}"
  location            = azurerm_resource_group.workload.location
  resource_group_name = azurerm_resource_group.workload.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "app" {
  name                      = "fic-${var.app_namespace}-${var.app_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.app.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = data.azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.app_namespace}:${var.app_service_account}"
}

# Grant least privilege so the app can only "read" Key Vault secrets (Secrets User = read values)
resource "azurerm_role_assignment" "app_reads_secrets" {
  scope                = data.azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant Secrets Officer so the user running Terraform can create the demo secret
resource "azurerm_role_assignment" "operator_writes_secrets" {
  scope                = data.azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Wait to avoid 403 / AADSTS70025-style errors caused by RBAC propagation delay (tens of seconds to a few minutes)
# and federated credential propagation delay. Secret creation (operator permission) and the pod's secret mount
# (app permission + federated credential) both happen after this wait.
resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"

  depends_on = [
    azurerm_role_assignment.operator_writes_secrets,
    azurerm_role_assignment.app_reads_secrets,
    azurerm_federated_identity_credential.app,
  ]
}

# ---------------------------------------------------------------------------
# Demo secret: uses an "ephemeral + write-only" combination so the value is never stored in state.
#   - ephemeral "random_password" : exists only in memory during plan/apply (Terraform 1.10+)
#   - value_wo / value_wo_version : write-only arguments, not recorded in state (Terraform 1.11+, azurerm 4.x and later)
# To change the value, increment value_wo_version.
# ---------------------------------------------------------------------------
ephemeral "random_password" "demo_secret" {
  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "demo" {
  name             = "demo-secret"
  key_vault_id     = data.azurerm_key_vault.this.id
  value_wo         = ephemeral.random_password.demo_secret.result
  value_wo_version = 1
  content_type     = "text/plain"
  tags             = local.tags

  depends_on = [time_sleep.rbac_propagation]
}
```
<!-- /tf:include -->

**`kubernetes.tf`** — Kubernetes side: Namespace, ServiceAccount, SecretProviderClass, Deployment

<!-- tf:include path="terraform/06-workload/kubernetes.tf" -->
```hcl title="terraform/06-workload/kubernetes.tf"
# ---------------------------------------------------------------------------
# Kubernetes side: Namespace / ServiceAccount / SecretProviderClass / Deployment
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace

    labels = {
      # Pod Security Admission: enforce the restricted profile (rejects running as root, privilege escalation, etc.)
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }
}

resource "kubernetes_service_account_v1" "app" {
  metadata {
    name      = var.app_service_account
    namespace = kubernetes_namespace_v1.app.metadata[0].name

    annotations = {
      # Equivalent to eks.amazonaws.com/role-arn on EKS
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.app.client_id
    }
  }

  depends_on = [azurerm_federated_identity_credential.app]
}

# CRD that defines which objects the Secrets Store CSI Driver fetches from Key Vault.
# (kubernetes_manifest connects to the cluster at plan time to read the CRD schema.)
resource "kubernetes_manifest" "secret_provider_class" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"

    metadata = {
      name      = "kv-demo"
      namespace = kubernetes_namespace_v1.app.metadata[0].name
    }

    spec = {
      provider = "azure"

      parameters = {
        usePodIdentity = "false"
        clientID       = azurerm_user_assigned_identity.app.client_id
        keyvaultName   = data.azurerm_key_vault.this.name
        tenantId       = data.azurerm_client_config.current.tenant_id

        objects = <<-EOT
          array:
            - |
              objectName: demo-secret
              objectType: secret
        EOT
      }
    }
  }
}

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = local.app_name }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.app_name }
    }

    template {
      metadata {
        labels = {
          app = local.app_name
          # The Workload Identity webhook injects the token volume and env vars only for pods with this label.
          "azure.workload.identity/use" = "true"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.app.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 65532

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "app"
          image   = local.app_image
          command = ["sh", "-c", "while true; do sleep 3600; done"]

          resources {
            requests = {
              cpu    = "50m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "64Mi"
            }
          }

          # The kubernetes provider sends false for any value omitted from a container security_context.
          # Without an explicit run_as_non_root it overrides the pod-level true and PSS restricted rejects the pod.
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }
        }

        volume {
          name = "secrets-store"

          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true

            volume_attributes = {
              secretProviderClass = "kv-demo"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.secret_provider_class,
    azurerm_key_vault_secret.demo,
    azurerm_role_assignment.app_reads_secrets,
    time_sleep.rbac_propagation,
  ]
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/06-workload/outputs.tf" -->
```hcl title="terraform/06-workload/outputs.tf"
output "app_identity_client_id" {
  description = "Client ID of the app UAMI (value for the ServiceAccount annotation)"
  value       = azurerm_user_assigned_identity.app.client_id
}

output "namespace" {
  description = "Demo namespace"
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "verify_command" {
  description = "Check that the Key Vault secret is mounted in the pod"
  value       = "kubectl -n ${var.app_namespace} exec deploy/${local.app_name} -- cat /mnt/secrets-store/demo-secret"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/06-workload/tests/plan.tftest.hcl" -->
```hcl title="terraform/06-workload/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/06-workload test
# (The mock provider does not support ephemeral resources, so random uses the real provider. No credentials are needed.)
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}
mock_provider "time" {}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.app.subject == "system:serviceaccount:demo:workload-sa"
    error_message = "The federated credential subject must have the format system:serviceaccount:<ns>:<sa>."
  }

  assert {
    condition     = azurerm_federated_identity_credential.app.audience == tolist(["api://AzureADTokenExchange"])
    error_message = "The audience must be api://AzureADTokenExchange."
  }
}
```
<!-- /tf:include -->

## Walkthrough

### Step 1. Import the demo image into ACR

As with ECR's *pull through cache*, the best practice is to **go through a private registry** rather than pull external images directly. (Skip this step if you already did it in Lab 04.)

```bash
ACR=$(terraform -chdir=terraform/04-platform output -raw acr_name)     # run from the repository root
az acr import -n "$ACR" --source mcr.microsoft.com/cbl-mariner/busybox:2.0 --image demo/busybox:2.0
```

### Step 2. Apply

```bash
cd terraform/06-workload
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # kubernetes_manifest connects to the cluster during plan to read the CRD schema
terraform apply tfplan            # about 3–5 min (includes the 90 s RBAC wait)
```

> [!NOTE]
> `kubelogin` and `kubectl` use your `az login` session. If you get an `executable kubelogin not found` error, check the tool installation in [Lab 01](01-prerequisites.md).

### Step 3. Verify

```bash
kubectl -n demo get pods,sa
kubectl -n demo rollout status deploy/kv-demo

# ① Is the Key Vault value mounted in the pod?
kubectl -n demo exec deploy/kv-demo -- cat /mnt/secrets-store/demo-secret; echo

# ② Read the same value directly as a human administrator
az keyvault secret show --vault-name "$(terraform -chdir=../04-platform output -raw key_vault_name)" -n demo-secret --query value -o tsv
```

If the two values match, it worked. Now take a look at **what was injected**.

```bash
# Environment variables and token file injected by the Workload Identity webhook
kubectl -n demo exec deploy/kv-demo -- env | grep -E "AZURE_"
#   AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE / AZURE_AUTHORITY_HOST

# Claims of the projected SA token (iss / sub / aud). A JWT is base64url without padding, so base64 -d alone can truncate it; decode it with python instead.
kubectl -n demo exec deploy/kv-demo -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | python3 -c 'import sys,base64,json; t=sys.stdin.read().strip().split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))), indent=2))'
```

`iss` is the `oidc_issuer_url`, `sub` is `system:serviceaccount:demo:workload-sa`, and `aud` is `api://AzureADTokenExchange`. The token exchange succeeds only if all three values match the federated credential.

### Step 4. Check automatic secret refresh

```bash
KV=$(terraform -chdir=../04-platform output -raw key_vault_name)
az keyvault secret set --vault-name "$KV" -n demo-secret --value "rotated-$(date +%s)" >/dev/null

sleep 150    # secret_rotation_interval = 2m
kubectl -n demo exec deploy/kv-demo -- cat /mnt/secrets-store/demo-secret; echo
```

> [!TIP]
> The app only picks up the new value when it re-reads the file. To use the secret as an environment variable, a common pattern is to sync a Kubernetes Secret through the CSI driver's `secretObjects` and pair it with a tool such as Reloader.

### Step 5. (Optional) Check private DNS

Check that nodes and pods resolve Key Vault and ACR to **private IPs**.

```bash
kubectl -n demo exec deploy/kv-demo -- nslookup "$KV.vault.azure.net" 2>/dev/null || \
kubectl run -it --rm dnscheck --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 --restart=Never -- nslookup "$KV.vault.azure.net"
# If you see a 10.10.3.x address from privatelink.vaultcore.azure.net, the traffic takes the Private Endpoint path.
```

### Automated verification script

It checks the whole chain end to end: the Azure side (UAMI · federated credential issuer/subject · Key Vault role) and the Kubernetes side (ServiceAccount annotation · pod label · injected environment variables · mounted secret). It **does not print the secret value**.

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 06-workload
```

<!-- tf:include path="scripts/verify/06-workload.sh" -->
```bash title="scripts/verify/06-workload.sh"
#!/usr/bin/env bash
# Lab 06 verification: checks that Workload Identity (the equivalent of IRSA) and the Key Vault CSI driver
# are connected end to end (read-only).
#   Azure side : app UAMI ← Federated credential (issuer + subject) ← Key Vault Secrets User role
#   Kubernetes : ServiceAccount annotation → pod label → injected environment variable → mounted secret
# Usage: scripts/verify.sh 06-workload
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local client_id ns rg aks_name kv kv_id uami uami_name uami_rg uami_pid fic subject sa sa_json dep
  client_id="$(tf_out 06-workload app_identity_client_id)"
  ns="$(tf_out 06-workload namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"
  kv="$(tf_out 04-platform key_vault_name)"

  section "06-workload · Azure side (UAMI · Federated credential · role)"
  if [ -z "$client_id" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 06-workload?"
    return
  fi

  # Find the UAMI in the subscription by its client ID.
  uami="$(jv "$(azj identity list)" "[.[] | select(.clientId == \"$client_id\")][0]")"
  uami_name="$(jv "$uami" .name)"
  uami_rg="$(jv "$uami" .resourceGroup)"
  uami_pid="$(jv "$uami" .principalId)"
  expect_set "App UAMI" "$uami_name"
  [ -n "$uami_name" ] || return

  fic="$(azj identity federated-credential list --identity-name "$uami_name" -g "$uami_rg")"
  subject="$(jv "$fic" '[.[].subject | select(startswith("system:serviceaccount:"))][0]')"
  sa="${subject##*:}"
  sa="${sa:-${TF_VAR_app_service_account:-workload-sa}}" # If there is no federated credential, keep checking with the default name.
  expect_eq "Namespace in the Federated credential subject" "${subject%:*}" "system:serviceaccount:$ns"
  expect_eq "Federated credential issuer = cluster OIDC issuer" "$(jv "$fic" '.[0].issuer')" "$(tf_out 05-aks oidc_issuer_url)"

  kv_id="$(az keyvault show -n "$kv" --query id -o tsv 2>/dev/null)"
  has_role "App UAMI → Key Vault Secrets User (least privilege, read-only)" "$uami_pid" "Key Vault Secrets User" "$kv_id"

  section "06-workload · Kubernetes side (ServiceAccount · pod · secret mount)"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi

  sa_json="$(kj get serviceaccount "$sa" -n "$ns")"
  expect_eq "ServiceAccount client-id annotation (the equivalent of IRSA's role-arn)" \
    "$(jv "$sa_json" '.metadata.annotations["azure.workload.identity/client-id"]')" "$client_id"

  dep="$(kj get deployment kv-demo -n "$ns")"
  jq_ok "Deployment kv-demo is ready" "$dep" '(.status.readyReplicas // 0) >= 1'
  expect_eq "Pod label azure.workload.identity/use (condition for webhook injection)" \
    "$(jv "$dep" '.spec.template.metadata.labels["azure.workload.identity/use"]')" "true"

  # Check inside the pod: the environment variable injected by the webhook and the secret file mounted
  # by the CSI driver (values are not printed)
  expect_eq "AZURE_CLIENT_ID injected into the pod" \
    "$(kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- printenv AZURE_CLIENT_ID 2>/dev/null)" "$client_id"
  if kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- test -s /mnt/secrets-store/demo-secret 2>/dev/null; then
    pass "Key Vault secret mounted in the pod (/mnt/secrets-store/demo-secret)"
  else
    fail "Secret file is missing or empty (look for mount errors in the events of kubectl -n $ns describe pod)"
  fi
}

# You can also run it directly (scripts/verify/06-workload.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## Common issues

| Symptom | Cause / Fix |
|---|---|
| `AADSTS70021: No matching federated identity record found` | The federated credential's `issuer`/`subject` does not match. Check the namespace, the SA name, and `oidc_issuer_url` (including case and any trailing `/`). |
| `AADSTS700211`/`AADSTS700213` | The audience is not `api://AzureADTokenExchange`. |
| Pod stuck in `ContainerCreating` (`failed to mount secrets store objects`) | The KV permission (Secrets User) has not propagated yet, the KV firewall is blocking access, or there is a typo in the SecretProviderClass `clientID`/`tenantId`/`objects`. Check the events in `kubectl describe pod`. |
| `ImagePullBackOff` | `az acr import` was skipped, or the kubelet's AcrPull permission has not propagated yet. |
| `kubernetes_manifest ... no matches for kind "SecretProviderClass"` during plan | The Key Vault CSI add-on is not enabled → check `key_vault_secrets_provider` in Lab 05. |
| `Forbidden` (creating the secret) | Your current IP is not on the Key Vault firewall allow list → see `allowed_ip_ranges` in Lab 01/04. |

Next → [Lab 07. Ingress: Gateway API](07-ingress.md)
