<!-- lang-switch -->
[English](../07-ingress.md) | **한국어**
<!-- /lang-switch -->

# Lab 07. 인그레스: ALB Controller → Gateway API (approuting-istio)

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 30분 | 공인 IP + 로드밸런서 + 파드 3개 (소액) | `terraform/07-ingress` | [05. AKS 클러스터](05-aks.md) |

## 이번 실습에서 만드는 것

![Gateway API 트래픽 흐름](diagrams/ingress-flow.svg)

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| ALB + AWS Load Balancer Controller (`Ingress`) | **Gateway API** `Gateway` + `HTTPRoute` (GatewayClass `approuting-istio`) | Ingress 의 annotation 대신 표준 API 필드로 라우팅/TLS/가중치를 선언합니다. |
| ALB 리스너 / 규칙 / 대상 그룹 | `Gateway.listeners` / `HTTPRoute.rules` / `backendRefs` | 역할 분리: Gateway(인프라) ↔ HTTPRoute(앱). |
| `internal` vs `internet-facing` 스킴 | Gateway 의 `infrastructure.annotations` (`azure-load-balancer-internal`) | 내부 LB 는 `snet-ingress` 서브넷의 사설 IP 를 사용. |
| NLB (`Service type=LoadBalancer`) | **Azure Load Balancer Standard** (`Service type=LoadBalancer`) | L4. 별도 컨트롤러 설치 없이 AKS 가 관리. |
| AWS WAF | **Application Gateway(WAF v2)** / **Front Door WAF** | 앞단에 두는 것이 Microsoft 베이스라인의 기본 구조. |
| ACM 인증서 | **Key Vault** 인증서 → Secrets Store CSI 로 동기화 | HTTPS 리스너 구성 시 사용 (아래 *TLS* 참고). |

> [!WARNING]
> **ingress-nginx 는 종료되었습니다.** 커뮤니티 ingress-nginx 는 2026-03 에 유지보수가 끝났고, AKS 의 *애플리케이션 라우팅 애드온(NGINX)* 에 대한 Microsoft 보안 패치 지원도 **2026-11** 에 종료됩니다. 신규 구축은 Gateway API 를 쓰세요. 새 AKS Automatic 클러스터(1.36+)는 기본으로 Gateway API 입니다.

### 인그레스 선택지 한눈에 보기

| 선택지 | 특징 | 언제 |
|---|---|---|
| **App Routing Gateway API** (이 실습) | 사이드카 없는 관리형 Istio 컨트롤 플레인 + Envoy. 업그레이드는 AKS 와 함께. | 대부분의 HTTP/HTTPS 인그레스 (헤더/바디 크기 제한, Lua, rate limit 은 미지원) |
| **Application Gateway for Containers** | 클러스터 밖의 완전 관리형 L7(ALB 에 가장 가까움), WAF 연동 | 고성능/WAF 필요, 클러스터 밖 L7 선호 |
| Istio 서비스 메시 애드온 + Gateway API | 메시 기능 + 인그레스 | mTLS/트래픽 정책이 필요할 때 (App Routing Gateway API 와 동시 사용 불가) |
| 자체 관리 (Envoy Gateway, NGINX Gateway Fabric 등) | 완전한 통제 | 관리형이 지원하지 않는 기능이 필요할 때 |

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| 앱 컨테이너를 **ACR 에서** pull (`az acr import`) | 공용 레지스트리 장애/레이트 리밋 의존 제거, 이미지 스캔·감사. kubelet 의 `AcrPull` + Private Endpoint 경로를 그대로 검증합니다. |
| Deployment: **requests/limits, probes, 비루트, capabilities drop, seccomp, 영역 분산(best-effort)** | Azure Policy 베이스라인(Lab 08)과 AKS Automatic 의 *Deployment Safeguards* 를 통과하는 구성. 영역 분산은 `ScheduleAnyway` 라 자원이 부족하면 한 영역에 몰릴 수 있지만, `DoNotSchedule` 은 업그레이드/장애 때 파드가 Pending 에 머물 수 있어 의도적으로 택하지 않았습니다. |
| `PodDisruptionBudget` + `HPA(3~10)` | 노드 업그레이드/드레인 중에도 가용성 유지, 부하에 따른 자동 확장. |
| NetworkPolicy: **앱 파드는 같은 네임스페이스(`web`)의 파드에서 오는 8080 만 허용** | Cilium 이 강제하는 네임스페이스 단위 격리. Envoy 프록시가 같은 네임스페이스에 만들어지므로 통과합니다. ⚠️ `pod_selector {}` 는 `web` 안의 *모든* 파드를 허용합니다. 더 좁히려면 `kubectl -n web get pods --show-labels` 로 Envoy 파드의 실제 라벨을 확인한 뒤 그 라벨로 제한하세요. (NetworkPolicy 는 앱 파드에만 적용해야 Envoy 의 외부 수신이 막히지 않습니다.) |
| 네임스페이스 PSS: `baseline` 강제 + `restricted` 경고 | Envoy 프록시 파드가 같은 네임스페이스에 만들어지므로 enforce 는 baseline. |
| `internal_gateway` 변수 | 공용/내부 노출을 코드 한 줄로 전환. 운영에서는 내부 LB + Application Gateway(WAF) 조합이 일반적입니다. |
| 공용 Gateway 의 인바운드는 **03-network 노드 NSG** 에서 허용 | Standard LB 는 인바운드가 기본적으로 닫혀 있고, AKS 는 서브넷에 연결한 NSG 에 규칙을 추가하지 않습니다. 03-network 의 `AllowGatewayHttpHttps`(80/443, 출발지 `gateway_allowed_source_prefixes`)가 그 역할을 하며, 내부 Gateway 는 VNet 안 트래픽을 기본 규칙(`AllowVnetInBound`)이 허용합니다. |

## 코드

<!-- tf:include path="terraform/07-ingress/versions.tf" -->
```hcl title="terraform/07-ingress/versions.tf"
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
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "07-ingress.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/07-ingress/providers.tf" -->
```hcl title="terraform/07-ingress/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {}
}

# Same as 06-workload: kubelogin gets an Entra ID token to connect to the API server.
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

<!-- tf:include path="terraform/07-ingress/variables.tf" -->
```hcl title="terraform/07-ingress/variables.tf"
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

variable "namespace" {
  description = "Namespace for the web app and Gateway. The Envoy proxy that the Gateway creates also runs in this namespace."
  type        = string
  default     = "web"
}

variable "app_image" {
  description = <<-EOT
    Web app image. If left empty, <acr>.azurecr.io/demo/aspnetapp:v1 is used.
    Import it into ACR beforehand with `az acr import` (see Lab 07).
  EOT
  type        = string
  default     = ""
}

variable "internal_gateway" {
  description = <<-EOT
    If true, the Gateway is exposed through an internal load balancer (private IP in the snet-ingress subnet).
    If false (default), it is exposed through a public IP (like choosing the ALB internet-facing vs. internal scheme).
  EOT
  type        = bool
  default     = false
}

variable "ingress_subnet_name" {
  description = "Subnet name for the load balancer frontend IP when internal_gateway=true (snet-ingress from 03-network)"
  type        = string
  default     = "snet-ingress"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/07-ingress/main.tf" -->
```hcl title="terraform/07-ingress/main.tf"
data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  app_name = "aspnetapp"
  app_image = (
    var.app_image != "" ? var.app_image : "${data.azurerm_container_registry.this.login_server}/demo/aspnetapp:v1"
  )
}

data "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  resource_group_name = module.naming.names.rg_aks
}

data "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  resource_group_name = module.naming.names.rg_platform
}
```
<!-- /tf:include -->

**`app.tf`** — 데모 앱과 운영 필수 리소스(PDB, HPA, NetworkPolicy)

<!-- tf:include path="terraform/07-ingress/app.tf" -->
```hcl title="terraform/07-ingress/app.tf"
# ---------------------------------------------------------------------------
# Demo web app (ASP.NET sample): Namespace / Deployment / Service / PDB / HPA / NetworkPolicy
# Includes every production recommendation (resource requests/limits, probes, non-root user, zone spread, PDB, HPA).
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "web" {
  metadata {
    name = var.namespace

    labels = {
      # baseline is enforced; restricted violations are only reported as warnings.
      # (The Envoy proxy pods created by the Gateway run in the same namespace, so enforce stays at baseline.)
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
    labels    = { app = local.app_name }
  }

  lifecycle {
    # The HPA below manages replicas. Ignore the attribute so Terraform does not revert the value.
    ignore_changes = [spec[0].replicas]
  }

  spec {
    replicas = 3

    selector {
      match_labels = { app = local.app_name }
    }

    template {
      metadata {
        labels = { app = local.app_name }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1654 # non-root user 'app' in the .NET image

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Best-effort pod spread across availability zones: same as the topologySpreadConstraints used for AZ spread on AWS.
        # ScheduleAnyway does not block scheduling when the spread becomes unbalanced. DoNotSchedule is strict
        # but can leave pods Pending during upgrades or failures.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = { app = local.app_name }
          }
        }

        container {
          name  = "app"
          image = local.app_image

          port {
            container_port = 8080
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          # The kubernetes provider sends false for omitted security_context values, so set run_as_non_root explicitly.
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = "8080"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = "8080"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"

          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "app" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    selector = { app = local.app_name }
    type     = "ClusterIP"

    port {
      port        = 80
      target_port = "8080"
    }
  }
}

# Always keep at least 2 pods running, even during node upgrades/drains
resource "kubernetes_pod_disruption_budget_v1" "app" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    max_unavailable = "1"

    selector {
      match_labels = { app = local.app_name }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    min_replicas = 3
    max_replicas = 10

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

# NetworkPolicy enforced by Cilium: app pods accept only port 8080 traffic coming from "pods in the same namespace".
# The Gateway's Envoy proxy is created in the same namespace, so its traffic passes this rule.
# Note: pod_selector {} allows "all" pods in this namespace (other namespaces are blocked).
#       To narrow it, check the actual labels of the Envoy pods with `kubectl get pods -n web --show-labels`
#       and restrict the selector to those labels.
# (Similar to Security Groups applied per pod, but declared with Kubernetes label selectors.)
resource "kubernetes_network_policy_v1" "app" {
  metadata {
    name      = "${local.app_name}-allow-same-namespace"
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = local.app_name }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {}
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}
```
<!-- /tf:include -->

**`gateway.tf`** — Gateway 와 HTTPRoute

<!-- tf:include path="terraform/07-ingress/gateway.tf" -->
```hcl title="terraform/07-ingress/gateway.tf"
# ---------------------------------------------------------------------------
# Receiving external traffic with the Gateway API  (equivalent to Ingress/ALB in the AWS Load Balancer Controller)
#
#   GatewayClass(approuting-istio) : installed by AKS (enabled in the azapi step of 05-aks)
#   Gateway                        : port/protocol/load balancer exposure → platform team view (ALB + Listener)
#   HTTPRoute                      : host/path → service mapping          → app team view      (Listener rule + Target group)
#
# Applying a Gateway auto-creates an Envoy proxy Deployment, LoadBalancer Service, HPA, and PDB in the same namespace.
# ---------------------------------------------------------------------------
locals {
  # Pass Service annotations for an Azure internal load balancer (private IP) only when internal_gateway = true.
  # (The key must be absent entirely depending on the condition, so this uses the tomap + merge pattern.)
  gateway_infrastructure = var.internal_gateway ? tomap({
    infrastructure = {
      annotations = {
        "service.beta.kubernetes.io/azure-load-balancer-internal"        = "true"
        "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" = var.ingress_subnet_name
      }
    }
  }) : tomap({})

  gateway_spec = merge(
    {
      gatewayClassName = "approuting-istio"

      listeners = [
        {
          name     = "http"
          port     = 80
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = {
              from = "Same"
            }
          }
        }
      ]
    },
    local.gateway_infrastructure,
  )
}

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"

    metadata = {
      name      = "web-gateway"
      namespace = kubernetes_namespace_v1.web.metadata[0].name
    }

    spec = local.gateway_spec
  }
}

resource "kubernetes_manifest" "http_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"

    metadata = {
      name      = local.app_name
      namespace = kubernetes_namespace_v1.web.metadata[0].name
    }

    spec = {
      parentRefs = [
        {
          name = "web-gateway"
        }
      ]

      rules = [
        {
          matches = [
            {
              path = {
                type  = "PathPrefix"
                value = "/"
              }
            }
          ]

          backendRefs = [
            {
              name = kubernetes_service_v1.app.metadata[0].name
              port = 80
            }
          ]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.gateway]
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/07-ingress/outputs.tf" -->
```hcl title="terraform/07-ingress/outputs.tf"
output "namespace" {
  description = "Web app namespace"
  value       = kubernetes_namespace_v1.web.metadata[0].name
}

output "app_image" {
  description = "Deployed image (must be imported into ACR beforehand)"
  value       = local.app_image
}

output "gateway_address_command" {
  description = "Look up the load balancer address assigned to the Gateway (assignment takes 1–3 min)"
  value       = "kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}'"
}

output "curl_command" {
  description = "Send a request to the Gateway address (when internal_gateway=false)"
  value       = "curl -i http://$(kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')/"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/07-ingress/tests/plan.tftest.hcl" -->
```hcl title="terraform/07-ingress/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/07-ingress test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}

run "plan_public_gateway" {
  command = plan

  assert {
    condition     = !contains(keys(local.gateway_spec), "infrastructure")
    error_message = "A public Gateway must not have infrastructure (annotations)."
  }
}

run "plan_internal_gateway" {
  command = plan

  variables {
    internal_gateway = true
  }

  assert {
    condition     = local.gateway_spec.infrastructure.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "An internal Gateway must have the internal LB annotation."
  }
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 앱 이미지를 ACR 로 가져오기

```bash
ACR=$(terraform -chdir=terraform/04-platform output -raw acr_name)
az acr import -n "$ACR" --source mcr.microsoft.com/dotnet/samples:aspnetapp --image demo/aspnetapp:v1
```

### 2단계. 적용

```bash
cd terraform/07-ingress
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

### 3단계. 검증

```bash
# Gateway 가 Programmed 이고 주소가 할당되었는가 (1~3분)
kubectl -n web get gateway,httproute
kubectl -n web get gateway web-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'

# Gateway 가 만들어 낸 리소스: Envoy Deployment/Service/HPA/PDB
kubectl -n web get deploy,svc,hpa,pdb

# 요청
IP=$(kubectl -n web get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')
curl -i "http://$IP/"

# 파드가 영역별로 분산되었는가
kubectl -n web get pods -l app=aspnetapp -o wide
kubectl -n web get pods -l app=aspnetapp -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c

# 액세스 로그 (Envoy 기본 활성, JSON 한 줄). Envoy 파드가 2개라 `deploy/...` 로는 한 파드의 로그만(시작 로그일 수도) 보이므로 라벨로 모두 봅니다
kubectl -n web logs -l gateway.networking.k8s.io/gateway-name=web-gateway --tail=3 --prefix
```

### 4단계. 동작 실험

```bash
# (a) 부하를 주고 HPA 가 늘어나는지 관찰
kubectl -n web get hpa -w &
kubectl -n web run load --rm -i --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- \
  sh -c 'for i in $(seq 1 3000); do wget -q -O- http://aspnetapp.web.svc.cluster.local/ >/dev/null; done'

# (b) NetworkPolicy: 다른 네임스페이스에서는 앱에 직접 접근할 수 없다
kubectl run np-test --rm -i --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- \
  wget -T 3 -qO- http://aspnetapp.web.svc.cluster.local/ || echo "차단됨 (기대한 동작)"

# (c) 내부 로드밸런서로 전환 → snet-ingress 의 사설 IP
terraform apply -var internal_gateway=true
kubectl -n web get gateway web-gateway -o jsonpath='{.status.addresses[0].value}{"\n"}'   # 10.10.2.x
```

> [!TIP]
> 파드와 Deployment 에 `kubectl` 을 더 연습하려면(로그, `exec`, `port-forward`, 롤아웃, 문제 해결) [부록 E](99-appendix.md) 를 보세요. 이 앱은 Terraform 이 관리하므로 실험은 연습용 네임스페이스에서 하세요. `kubectl` 로 바꾼 값은 다음 `terraform plan` 에 차이로 나타납니다(E-8).

### TLS (HTTPS) 로 확장하기

`Gateway` 에 `443/HTTPS` 리스너를 추가하고 `tls.certificateRefs` 로 쿠버네티스 Secret 을 가리킵니다. 노드 NSG(03-network)는 80 과 443 을 이미 허용하므로 NSG 를 고칠 필요가 없습니다. 인증서는 **Key Vault 에 두고 Secrets Store CSI 의 `secretObjects`** 로 Secret 에 동기화하는 것이 Microsoft 베이스라인 방식입니다(Lab 06 의 SecretProviderClass 패턴과 동일, `Key Vault Certificate User` 역할 필요). 자세한 절차는 [App Routing Gateway API: DNS 와 TLS](https://learn.microsoft.com/azure/aks/app-routing-gateway-api-dns-tls) 를 참고하세요.

### 자동 검증 스크립트

Gateway(Programmed) → HTTPRoute(Accepted) → Deployment/HPA/PDB/NetworkPolicy 를 확인하고, 공용 Gateway 라면 실제로 `curl` 요청을 보내 `200` 을 확인합니다(내부 Gateway 는 건너뜀).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 07-ingress
```

<!-- tf:include path="scripts/verify/07-ingress.sh" -->
```bash title="scripts/verify/07-ingress.sh"
#!/usr/bin/env bash
# Lab 07 verification: checks that the web app exposed through the Gateway API works (read-only).
#   Gateway (Programmed) → HTTPRoute (Accepted) → Service → Pod, plus PDB · HPA · NetworkPolicy
# Usage: scripts/verify.sh 07-ingress
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local ns rg aks_name gw addr route dep code i
  ns="$(tf_out 07-ingress namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"

  section "07-ingress · Gateway API (${ns:-?})"
  if [ -z "$ns" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 07-ingress?"
    return
  fi
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi

  # Spell out the API group so that the name doesn't clash with other CRDs such as istio's.
  gw="$(kj get gateway.gateway.networking.k8s.io web-gateway -n "$ns")"
  jq_ok "Gateway web-gateway is Programmed" "$gw" '.status.conditions[]? | select(.type == "Programmed") | .status == "True"'
  addr="$(jv "$gw" '.status.addresses[0].value')"
  expect_set "Load balancer address assigned to the Gateway" "$addr"

  route="$(kj get httproute.gateway.networking.k8s.io aspnetapp -n "$ns")"
  jq_ok "HTTPRoute aspnetapp is Accepted" "$route" '.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status == "True"'

  dep="$(kj get deployment aspnetapp -n "$ns")"
  jq_ok "Deployment aspnetapp: ready replicas = desired replicas" "$dep" '(.status.readyReplicas // 0) == .spec.replicas and .spec.replicas >= 1'
  jq_ok "HPA aspnetapp exists" "$(kj get hpa aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "PodDisruptionBudget aspnetapp exists" "$(kj get pdb aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "NetworkPolicy exists (allows only traffic from the same namespace)" \
    "$(kj get networkpolicy aspnetapp-allow-same-namespace -n "$ns")" '.metadata.name == "aspnetapp-allow-same-namespace"'

  # Real request: an internal (private IP) Gateway can't be reached from outside the VNet, so skip it.
  if printf '%s' "$addr" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
    skip "Internal Gateway ($addr) is reachable only from inside the VNet; skipping curl"
  elif [ -n "$addr" ]; then
    code=""
    for i in 1 2 3 4 5 6; do # A load balancer that was just created can take about a minute to respond.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$addr/" 2>/dev/null || true)"
      [ "$code" = "200" ] && break
      [ "$i" -lt 6 ] && sleep 10
    done
    expect_eq "GET http://$addr/ response code" "$code" "200"
  fi
}

# You can also run it directly (scripts/verify/07-ingress.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `Gateway` 의 `ADDRESS` 가 비어 있음 | LB 프로비저닝 대기(1–3분). `kubectl -n web describe gateway web-gateway` 의 Conditions 와 `kubectl -n web get events` 확인. 공인 IP 쿼터 부족일 수 있습니다. |
| plan 오류 `no matches for kind "Gateway"` / GatewayClass 없음 | Lab 05 의 `azapi_update_resource.gateway_api` 가 적용되지 않음 (`enable_gateway_api=false` 였는지 확인). `kubectl get gatewayclass`. |
| `ImagePullBackOff` | `az acr import` 누락(이미지 경로 `demo/aspnetapp:v1`). `kubectl describe pod` 확인. |
| `curl` 이 타임아웃 | 03-network 노드 서브넷 NSG 의 `AllowGatewayHttpHttps` 규칙(AKS 는 서브넷에 연결한 NSG 를 수정하지 않으므로 Terraform 이 만든 규칙이 필요)과 `gateway_allowed_source_prefixes` 에 내 IP 가 포함되는지 확인, 내부 Gateway(`internal_gateway=true`)인데 VNet 밖에서 접근, 또는 NetworkPolicy. |
| HTTPRoute 가 `Accepted: False` | `parentRefs` 이름 불일치 또는 `allowedRoutes`(Same namespace) 위반. |

다음 → [Lab 08. 거버넌스와 보안: Azure Policy · Defender · 예산](08-governance.md)
