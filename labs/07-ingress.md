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
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {}
}

# 06-workload 와 동일: kubelogin 으로 Entra ID 토큰을 받아 API 서버에 접속합니다.
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

variable "namespace" {
  description = "웹 앱과 Gateway 를 배포할 네임스페이스. Gateway 가 만드는 Envoy 프록시도 같은 네임스페이스에 생깁니다."
  type        = string
  default     = "web"
}

variable "app_image" {
  description = <<-EOT
    웹 앱 이미지. 비워 두면 <acr>.azurecr.io/demo/aspnetapp:v1 을 사용합니다.
    사전에 `az acr import` 로 ACR 에 넣어 두어야 합니다 (Lab 07 참고).
  EOT
  type        = string
  default     = ""
}

variable "internal_gateway" {
  description = <<-EOT
    true 이면 Gateway 를 내부 로드밸런서(snet-ingress 서브넷의 사설 IP)로 노출합니다.
    false(기본값)이면 공인 IP 로 노출합니다 (ALB internet-facing / internal 스킴 선택과 같은 개념).
  EOT
  type        = bool
  default     = false
}

variable "ingress_subnet_name" {
  description = "internal_gateway=true 일 때 로드밸런서 프런트엔드 IP 를 할당할 서브넷 이름 (03-network 의 snet-ingress)"
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
# 데모 웹 앱 (ASP.NET 샘플) : Namespace / Deployment / Service / PDB / HPA / NetworkPolicy
# 프로덕션 권장 사항(리소스 요청·제한, probe, 비루트 실행, 영역 분산, PDB, HPA)을 모두 포함합니다.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "web" {
  metadata {
    name = var.namespace

    labels = {
      # baseline 은 강제, restricted 위반은 경고로 알려 줍니다.
      # (Gateway 가 만드는 Envoy 프록시 파드가 같은 네임스페이스에 생성되므로 enforce 는 baseline 으로 둡니다.)
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
    # replicas 는 아래 HPA 가 관리합니다. Terraform 이 값을 되돌리지 않도록 무시합니다.
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
          run_as_user     = 1654 # .NET 이미지의 비루트 사용자 'app'

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # 가용 영역(zone)별 파드 분산(best-effort): AWS 에서 AZ 분산을 위해 쓰던 topologySpreadConstraints 와 동일.
        # ScheduleAnyway 는 균형이 깨져도 스케줄을 막지 않습니다. DoNotSchedule 은 엄격하지만 업그레이드/장애 때 Pending 을 만들 수 있습니다.
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

          # kubernetes provider 는 컨테이너 security_context 에서 생략한 값을 false 로 보내므로 run_as_non_root 를 명시합니다.
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

# 노드 업그레이드/드레인 중에도 항상 최소 2개 파드는 유지
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

# Cilium 이 강제하는 NetworkPolicy: 앱 파드는 "같은 네임스페이스의 파드"에서 오는 8080 트래픽만 허용합니다.
# Gateway 의 Envoy 프록시가 같은 네임스페이스에 만들어지므로 이 규칙으로 통과합니다.
# 주의: pod_selector {} 는 이 네임스페이스의 "모든" 파드를 허용합니다(다른 네임스페이스는 차단).
#       더 좁히려면 `kubectl get pods -n web --show-labels` 로 Envoy 파드의 실제 라벨을 확인한 뒤 그 라벨로 selector 를 제한하세요.
# (Security Group 이 파드 단위로 적용되는 것과 비슷하지만, 쿠버네티스 라벨 셀렉터로 선언합니다.)
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
# Gateway API 로 외부 트래픽 받기  (AWS Load Balancer Controller 의 Ingress/ALB 에 해당)
#
#   GatewayClass(approuting-istio) : AKS 가 설치 (05-aks 의 azapi 단계에서 활성화)
#   Gateway                        : 포트/프로토콜/로드밸런서 노출 방식 → 플랫폼 팀 관점 (ALB + Listener)
#   HTTPRoute                      : 호스트/경로 → 서비스 매핑          → 앱 팀 관점   (Listener rule + Target group)
#
# Gateway 를 적용하면 같은 네임스페이스에 Envoy 프록시 Deployment, LoadBalancer Service, HPA, PDB 가 자동 생성됩니다.
# ---------------------------------------------------------------------------
locals {
  # internal_gateway = true 일 때만 Azure 내부 로드밸런서(사설 IP)를 쓰도록 Service annotation 을 전달합니다.
  # (조건에 따라 키 자체가 없어야 하므로 tomap + merge 패턴을 사용합니다.)
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
  description = "웹 앱 네임스페이스"
  value       = kubernetes_namespace_v1.web.metadata[0].name
}

output "app_image" {
  description = "배포된 이미지 (ACR 에 미리 import 되어 있어야 합니다)"
  value       = local.app_image
}

output "gateway_address_command" {
  description = "Gateway 에 할당된 로드밸런서 주소 조회 (할당까지 1~3분 소요)"
  value       = "kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}'"
}

output "curl_command" {
  description = "Gateway 주소로 요청 보내기 (internal_gateway=false 일 때)"
  value       = "curl -i http://$(kubectl -n ${var.namespace} get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')/"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/07-ingress/tests/plan.tftest.hcl" -->
```hcl title="terraform/07-ingress/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/07-ingress test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "kubernetes" {}

run "plan_public_gateway" {
  command = plan

  assert {
    condition     = !contains(keys(local.gateway_spec), "infrastructure")
    error_message = "공용 Gateway 에는 infrastructure(annotation)가 없어야 합니다."
  }
}

run "plan_internal_gateway" {
  command = plan

  variables {
    internal_gateway = true
  }

  assert {
    condition     = local.gateway_spec.infrastructure.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    error_message = "내부 Gateway 는 internal LB annotation 이 있어야 합니다."
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
# Lab 07 검증: Gateway API 로 노출한 웹 앱이 정상 동작하는지 확인합니다 (읽기 전용).
#   Gateway(Programmed) → HTTPRoute(Accepted) → Service → Pod, 그리고 PDB · HPA · NetworkPolicy
# 사용법: scripts/verify.sh 07-ingress
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local ns rg aks_name gw addr route dep code i
  ns="$(tf_out 07-ingress namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"

  section "07-ingress · Gateway API (${ns:-?})"
  if [ -z "$ns" ]; then
    fail "terraform output 을 읽을 수 없습니다. 07-ingress 에서 init/apply 를 마쳤나요?"
    return
  fi
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 Cluster User Role 확인)"
    return
  fi

  # istio 등 다른 CRD 와 이름이 겹치지 않도록 API 그룹까지 적습니다.
  gw="$(kj get gateway.gateway.networking.k8s.io web-gateway -n "$ns")"
  jq_ok "Gateway web-gateway 가 Programmed" "$gw" '.status.conditions[]? | select(.type == "Programmed") | .status == "True"'
  addr="$(jv "$gw" '.status.addresses[0].value')"
  expect_set "Gateway 에 할당된 로드밸런서 주소" "$addr"

  route="$(kj get httproute.gateway.networking.k8s.io aspnetapp -n "$ns")"
  jq_ok "HTTPRoute aspnetapp 이 Accepted" "$route" '.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status == "True"'

  dep="$(kj get deployment aspnetapp -n "$ns")"
  jq_ok "Deployment aspnetapp: 준비된 레플리카 = 원하는 수" "$dep" '(.status.readyReplicas // 0) == .spec.replicas and .spec.replicas >= 1'
  jq_ok "HPA aspnetapp 존재" "$(kj get hpa aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "PodDisruptionBudget aspnetapp 존재" "$(kj get pdb aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "NetworkPolicy 존재 (같은 네임스페이스에서 오는 트래픽만 허용)" \
    "$(kj get networkpolicy aspnetapp-allow-same-namespace -n "$ns")" '.metadata.name == "aspnetapp-allow-same-namespace"'

  # 실제 요청: 내부(사설 IP) Gateway 는 VNet 밖에서 접근할 수 없으므로 건너뜁니다.
  if printf '%s' "$addr" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
    skip "내부 Gateway($addr)는 VNet 안에서만 접근할 수 있어 curl 을 건너뜁니다"
  elif [ -n "$addr" ]; then
    code=""
    for i in 1 2 3 4 5 6; do # 방금 만든 로드밸런서는 응답까지 1분 정도 걸릴 수 있습니다.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$addr/" 2>/dev/null || true)"
      [ "$code" = "200" ] && break
      [ "$i" -lt 6 ] && sleep 10
    done
    expect_eq "GET http://$addr/ 응답 코드" "$code" "200"
  fi
}

# 직접 실행(scripts/verify/07-ingress.sh)도 가능합니다.
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
