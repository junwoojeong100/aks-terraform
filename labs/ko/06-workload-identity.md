<!-- lang-switch -->
[English](../06-workload-identity.md) | **한국어**
<!-- /lang-switch -->

# Lab 06. Workload Identity + Key Vault CSI: IRSA 의 Azure 버전

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 25분 | 거의 없음 (파드 1개) | `terraform/06-workload` | [05. AKS 클러스터](05-aks.md) |

## 이번 실습에서 만드는 것

파드가 **정적 비밀(키/비밀번호) 없이** Key Vault 시크릿을 읽는 전체 흐름입니다.

![Workload Identity 흐름 (IRSA 와 비교)](diagrams/workload-identity-flow.svg)

Azure 쪽 흐름을 단계별로 풀어 쓰면 다음과 같습니다.

```text
 Pod  (ServiceAccount: demo/workload-sa, label azure.workload.identity/use=true)
  │ ① kubelet 이 SA 토큰을 투영(projected token)해 파드에 마운트
  │    iss = 클러스터 OIDC issuer,  sub = system:serviceaccount:demo:workload-sa,  aud = api://AzureADTokenExchange
  ▼
 Microsoft Entra ID ── ② Federated credential(issuer + subject)이 일치하는 UAMI 를 찾아 ──► ③ Entra 액세스 토큰 발급
  ▼
 Key Vault  ── RBAC: 해당 UAMI 에 "Key Vault Secrets User" ──► CSI Driver 가 /mnt/secrets-store/demo-secret 로 마운트
```

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| IAM OIDC Provider (클러스터마다 등록) | 클러스터 **OIDC issuer** (`oidc_issuer_enabled`) | 별도 등록 불필요. issuer URL 은 `oidc_issuer_url` 출력으로 얻습니다. |
| IAM Role + Trust policy(`sub` 조건) | **UAMI + Federated identity credential**(`issuer`, `subject`, `audience`) | 신뢰 정책 JSON 대신 `azurerm_federated_identity_credential` 리소스. |
| ServiceAccount annotation `eks.amazonaws.com/role-arn` | annotation `azure.workload.identity/client-id` | 파드에는 추가로 label `azure.workload.identity/use: "true"` 가 필요합니다. |
| IAM Policy (secretsmanager:GetSecretValue) | 역할 할당 **Key Vault Secrets User** (데이터 평면) | `Contributor` 같은 관리 평면 역할로는 시크릿 값을 읽을 수 없습니다. |
| Secrets Manager + CSI provider | **Key Vault provider for Secrets Store CSI Driver** (AKS 애드온) | `SecretProviderClass` CRD 로 가져올 객체를 선언. 자동 갱신 간격(`secret_rotation_interval`) 지원. |
| EKS Pod Identity (association API) | (대응 없음) → *Identity bindings for AKS* | 한 UAMI 당 federated credential **20개 제한**이 있어, 여러 클러스터가 한 ID 를 공유할 때 Identity bindings 를 검토합니다. |

> [!IMPORTANT]
> 한 UAMI 에 연결할 수 있는 federated credential 은 **최대 20개**입니다. "앱(네임스페이스/SA)마다 UAMI 하나" 를 기본으로 설계하면 제한에 걸릴 일이 적고 권한도 최소화됩니다.

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| **쿠버네티스 리소스는 별도 스택(06)** 에서, 클러스터는 이미 존재하는 상태로 | 클러스터 생성과 같은 스택에서 `kubernetes` provider 를 쓰면 provider 설정이 apply 시점에 결정되어 계획/삭제가 꼬이기 쉽습니다. |
| `kubernetes` provider 인증 = **kubelogin + Azure CLI 토큰** | 로컬 계정을 껐기 때문에 정적 인증서/토큰이 없습니다. EKS 의 `aws eks get-token` exec 플러그인과 같은 패턴입니다. |
| 앱 전용 UAMI + **Secrets User(읽기)** 만 부여 | 최소 권한. 쓰기는 사람(Secrets Officer)만. |
| 시크릿 값은 **ephemeral + write-only(`value_wo`)** | Terraform state 에 값이 남지 않습니다 (Terraform 1.11+ write-only 인수, azurerm 5.x 지원). 값을 바꾸려면 `value_wo_version` 을 올립니다. |
| 네임스페이스에 **Pod Security `restricted`** 강제 | 비루트, 권한 상승 금지, seccomp 등 베이스라인 보안을 네임스페이스 단위로 강제. |
| RBAC 전파 대기용 `time_sleep` | 역할 할당 직후 데이터 평면 호출이 403 으로 실패하는 흔한 문제를 방지. 시크릿 생성(운영자 권한)과 파드의 시크릿 마운트(앱 권한 + 연합 자격 증명) 모두 이 대기 이후에 진행되도록 `depends_on` 으로 묶었습니다. |

## 코드

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

**`providers.tf`** — `kubernetes` provider 가 kubelogin 으로 접속하는 부분이 핵심입니다.

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

**`identity.tf`** — Azure 쪽: UAMI, Federated credential, 역할 할당, 시크릿

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

**`kubernetes.tf`** — 쿠버네티스 쪽: Namespace, ServiceAccount, SecretProviderClass, Deployment

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

## 실습 따라하기

### 1단계. 데모 이미지를 ACR 로 가져오기

ECR 의 *pull through cache* 처럼 외부 이미지를 직접 쓰지 않고 **사설 레지스트리를 경유**하는 것이 Best practice 입니다. (Lab 04 에서 이미 했다면 건너뛰세요.)

```bash
ACR=$(terraform -chdir=terraform/04-platform output -raw acr_name)     # 저장소 루트에서 실행
az acr import -n "$ACR" --source mcr.microsoft.com/cbl-mariner/busybox:2.0 --image demo/busybox:2.0
```

### 2단계. 적용

```bash
cd terraform/06-workload
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # kubernetes_manifest 는 plan 시 클러스터에 접속해 CRD 스키마를 읽습니다
terraform apply tfplan            # 약 3~5분 (RBAC 대기 90초 포함)
```

> [!NOTE]
> `kubelogin`/`kubectl` 이 `az login` 세션을 사용합니다. `executable kubelogin not found` 오류가 나면 [Lab 01](01-prerequisites.md)의 도구 설치를 확인하세요.

### 3단계. 검증

```bash
kubectl -n demo get pods,sa
kubectl -n demo rollout status deploy/kv-demo

# ① Key Vault 의 값이 파드에 마운트되었는가
kubectl -n demo exec deploy/kv-demo -- cat /mnt/secrets-store/demo-secret; echo

# ② 같은 값을 사람(관리자)이 직접 조회
az keyvault secret show --vault-name "$(terraform -chdir=../04-platform output -raw key_vault_name)" -n demo-secret --query value -o tsv
```

두 값이 같다면 성공입니다. 이제 **무엇이 주입되었는지** 들여다봅니다.

```bash
# Workload Identity webhook 이 주입한 환경 변수와 토큰 파일
kubectl -n demo exec deploy/kv-demo -- env | grep -E "AZURE_"
#   AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE / AZURE_AUTHORITY_HOST

# 투영된 SA 토큰의 클레임 (iss / sub / aud). JWT 는 base64url 이라 패딩이 없어서 base64 -d 만으로는 잘리는 경우가 있어 python 으로 풉니다.
kubectl -n demo exec deploy/kv-demo -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | python3 -c 'import sys,base64,json; t=sys.stdin.read().strip().split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))), indent=2))'
```

`iss` 는 `oidc_issuer_url`, `sub` 는 `system:serviceaccount:demo:workload-sa`, `aud` 는 `api://AzureADTokenExchange` 이며, 이 세 값이 Federated credential 과 일치해야 토큰 교환이 성공합니다.

### 4단계. 시크릿 자동 갱신 확인

```bash
KV=$(terraform -chdir=../04-platform output -raw key_vault_name)
az keyvault secret set --vault-name "$KV" -n demo-secret --value "rotated-$(date +%s)" >/dev/null

sleep 150    # secret_rotation_interval = 2m
kubectl -n demo exec deploy/kv-demo -- cat /mnt/secrets-store/demo-secret; echo
```

> [!TIP]
> 앱이 파일을 다시 읽어야 새 값을 씁니다. 환경 변수로 쓰려면 CSI 의 `secretObjects` 로 Kubernetes Secret 을 동기화하고 Reloader 같은 도구를 함께 쓰는 패턴이 흔합니다.

### 5단계. (선택) 사설 DNS 확인

노드/파드가 Key Vault·ACR 을 **사설 IP** 로 해석하는지 확인합니다.

```bash
kubectl -n demo exec deploy/kv-demo -- nslookup "$KV.vault.azure.net" 2>/dev/null || \
kubectl run -it --rm dnscheck --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 --restart=Never -- nslookup "$KV.vault.azure.net"
# privatelink.vaultcore.azure.net 의 10.10.3.x 주소가 보이면 Private Endpoint 경로입니다.
```

### 자동 검증 스크립트

Azure 쪽(UAMI · Federated credential issuer/subject · Key Vault 역할)과 쿠버네티스 쪽(ServiceAccount annotation · 파드 label · 주입된 환경 변수 · 마운트된 시크릿)을 끝까지 확인합니다. 시크릿 **값은 출력하지 않습니다**.

```bash
cd ../..                          # 저장소 루트에서 실행
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

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `AADSTS70021: No matching federated identity record found` | Federated credential 의 `issuer`/`subject` 불일치. 네임스페이스·SA 이름, `oidc_issuer_url` 을 확인하세요(대소문자/후행 `/` 포함). |
| `AADSTS700211`/`AADSTS700213` | audience 가 `api://AzureADTokenExchange` 가 아님. |
| 파드가 `ContainerCreating` 에서 멈춤 (`failed to mount secrets store objects`) | KV 권한(Secrets User) 전파 지연, KV 방화벽, 또는 SecretProviderClass 의 `clientID`/`tenantId`/`objects` 오타. `kubectl describe pod` 이벤트 확인. |
| `ImagePullBackOff` | `az acr import` 누락 또는 kubelet 의 AcrPull 권한 전파 지연. |
| plan 에서 `kubernetes_manifest ... no matches for kind "SecretProviderClass"` | Key Vault CSI 애드온 미활성 → Lab 05 의 `key_vault_secrets_provider` 확인. |
| `Forbidden` (secret 생성) | 현재 IP 가 Key Vault 방화벽 허용 목록에 없음 → Lab 01/04 의 `allowed_ip_ranges`. |

다음 → [Lab 07. 인그레스: Gateway API](07-ingress.md)
