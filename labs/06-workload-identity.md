# Lab 06. Workload Identity + Key Vault CSI: IRSA 의 Azure 버전

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 25분 | 거의 없음 (파드 1개) | `terraform/06-workload` | [05. AKS 클러스터](05-aks.md) |

## 이번 실습에서 만드는 것

파드가 **정적 비밀(키/비밀번호) 없이** Key Vault 시크릿을 읽는 전체 흐름입니다.

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
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ---------------------------------------------------------------------------
# kubernetes provider → 05-aks 가 만든 클러스터에 접속
#   - 클러스터가 "이미 존재" 하는 상태에서 별도 스택으로 실행하므로, provider 설정이 apply 시점에 결정되는
#     리소스에 의존하지 않습니다 (클러스터 생성과 같은 스택에서 kubernetes provider 를 쓰면 흔히 겪는 문제 회피).
#   - 로컬 계정이 꺼져 있으므로 정적 인증서 대신 kubelogin 이 Azure CLI 로그인으로 토큰을 받아옵니다.
#     (EKS 의 `aws eks get-token` exec 플러그인과 같은 방식. server-id 는 AKS 의 Entra 서버 앱 ID 로 고정값입니다.)
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

variable "app_namespace" {
  description = "데모 앱을 배포할 쿠버네티스 네임스페이스"
  type        = string
  default     = "demo"
}

variable "app_service_account" {
  description = "Workload Identity 에 연결할 쿠버네티스 ServiceAccount 이름"
  type        = string
  default     = "workload-sa"
}

variable "app_image" {
  description = <<-EOT
    데모 컨테이너 이미지. 비워 두면 <acr>.azurecr.io/demo/busybox:2.0 을 사용합니다.
    사전에 `az acr import` 로 ACR 에 넣어 두어야 합니다 (Lab 06 참고).
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

# 앞선 스택이 만든 리소스를 이름 규칙으로 조회
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
# Azure 쪽: 앱 전용 Managed Identity + 연합 자격 증명(Federated Credential) + 최소 권한
#
# IRSA 와의 대응
#   AWS  : IAM Role + OIDC Provider(클러스터별) + trust policy(sub 조건) + SA annotation(role-arn)
#   Azure: UAMI + Federated credential(issuer + subject) + SA annotation(client-id) + 파드 label
# 두 방식 모두 "쿠버네티스 SA 토큰 → 클라우드 임시 자격 증명" 교환이며 정적 키가 필요 없습니다.
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

# 앱이 Key Vault 시크릿을 "읽기만" 할 수 있도록 최소 권한 부여 (Secrets User = 값 읽기)
resource "azurerm_role_assignment" "app_reads_secrets" {
  scope                = data.azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

# Terraform 을 실행하는 사용자가 데모 시크릿을 만들 수 있도록 Secrets Officer 부여
resource "azurerm_role_assignment" "operator_writes_secrets" {
  scope                = data.azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RBAC 전파 지연(수십 초~수 분)과 연합 자격 증명 반영 지연으로 인한 403 / AADSTS70025 류 오류를 피하기 위한 대기.
# 시크릿 생성(operator 권한)과 파드의 시크릿 마운트(앱 권한 + 연합 자격 증명)가 모두 이 대기 이후에 진행됩니다.
resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"

  depends_on = [
    azurerm_role_assignment.operator_writes_secrets,
    azurerm_role_assignment.app_reads_secrets,
    azurerm_federated_identity_credential.app,
  ]
}

# ---------------------------------------------------------------------------
# 데모 시크릿: 값이 state 에 저장되지 않도록 "ephemeral + write-only" 조합을 사용합니다.
#   - ephemeral "random_password" : plan/apply 중 메모리에만 존재 (Terraform 1.10+)
#   - value_wo / value_wo_version : write-only 인수. state 에 기록되지 않음 (Terraform 1.11+, azurerm 4.x 이후)
# 값을 바꾸고 싶으면 value_wo_version 을 올립니다.
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
# 쿠버네티스 쪽: Namespace / ServiceAccount / SecretProviderClass / Deployment
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace

    labels = {
      # Pod Security Admission: restricted 프로파일을 강제 (root 실행, 권한 상승 등을 거부)
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
      # EKS 의 eks.amazonaws.com/role-arn 에 해당
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.app.client_id
    }
  }

  depends_on = [azurerm_federated_identity_credential.app]
}

# Secrets Store CSI Driver 가 Key Vault 에서 가져올 객체를 정의하는 CRD.
# (kubernetes_manifest 는 plan 시점에 클러스터에 접속해 CRD 스키마를 읽습니다.)
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
          # 이 label 이 있어야 Workload Identity webhook 이 토큰 볼륨/환경 변수를 주입합니다.
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

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

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
  description = "앱 UAMI 의 client ID (ServiceAccount annotation 값)"
  value       = azurerm_user_assigned_identity.app.client_id
}

output "namespace" {
  description = "데모 네임스페이스"
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "verify_command" {
  description = "Key Vault 시크릿이 파드에 마운트되었는지 확인"
  value       = "kubectl -n ${var.app_namespace} exec deploy/${local.app_name} -- cat /mnt/secrets-store/demo-secret"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/06-workload/tests/plan.tftest.hcl" -->
```hcl title="terraform/06-workload/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/06-workload test
# (ephemeral 리소스는 mock provider 가 지원하지 않으므로 random 은 실제 provider 를 사용합니다. 자격 증명은 필요 없습니다.)
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}
mock_provider "time" {}

run "plan" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.app.subject == "system:serviceaccount:demo:workload-sa"
    error_message = "federated credential subject 는 system:serviceaccount:<ns>:<sa> 형식이어야 합니다."
  }

  assert {
    condition     = azurerm_federated_identity_credential.app.audience == tolist(["api://AzureADTokenExchange"])
    error_message = "audience 는 api://AzureADTokenExchange 여야 합니다."
  }
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 데모 이미지를 ACR 로 가져오기

ECR 의 *pull through cache* 처럼 외부 이미지를 직접 쓰지 않고 **사설 레지스트리를 경유**하는 것이 Best practice 입니다. (Lab 04 에서 이미 했다면 건너뛰세요.)

```bash
ACR=$(terraform -chdir=../04-platform output -raw acr_name)
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

# 투영된 SA 토큰의 클레임 (iss / sub / aud)
kubectl -n demo exec deploy/kv-demo -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -m json.tool
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
