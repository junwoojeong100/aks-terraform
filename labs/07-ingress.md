<!-- lang-switch -->
**English** | [한국어](ko/07-ingress.md)
<!-- /lang-switch -->

# Lab 07. Ingress: ALB Controller → Gateway API (approuting-istio)

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 30 min | Public IP + load balancer + 3 pods (a small charge) | `terraform/07-ingress` | [05. AKS cluster](05-aks.md) |

## What you build in this lab

![Gateway API traffic flow](diagrams/ingress-flow.svg)

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| ALB + AWS Load Balancer Controller (`Ingress`) | **Gateway API** `Gateway` + `HTTPRoute` (GatewayClass `approuting-istio`) | You declare routing, TLS and weights with standard API fields instead of Ingress annotations. |
| ALB listeners / rules / target groups | `Gateway.listeners` / `HTTPRoute.rules` / `backendRefs` | Separation of roles: Gateway (infrastructure) ↔ HTTPRoute (app). |
| `internal` vs. `internet-facing` scheme | The Gateway's `infrastructure.annotations` (`azure-load-balancer-internal`) | An internal LB uses a private IP from the `snet-ingress` subnet. |
| NLB (`Service type=LoadBalancer`) | **Azure Load Balancer Standard** (`Service type=LoadBalancer`) | L4. AKS manages it, with no separate controller to install. |
| AWS WAF | **Application Gateway (WAF v2)** / **Front Door WAF** | Putting it in front is the default architecture in the Microsoft baseline. |
| ACM certificates | **Key Vault** certificates → synced with the Secrets Store CSI driver | Used when you configure an HTTPS listener (see *TLS* below). |

> [!WARNING]
> **ingress-nginx has been retired.** Maintenance of the community ingress-nginx ended in 2026-03, and Microsoft security patch support for the AKS *application routing add-on (NGINX)* also ends in **2026-11**. Use Gateway API for new deployments. New AKS Automatic clusters (1.36+) use Gateway API by default.

### Ingress options at a glance

| Option | Characteristics | When to use |
|---|---|---|
| **App Routing Gateway API** (this lab) | Managed Istio control plane without sidecars, plus Envoy. It is upgraded together with AKS. | Most HTTP/HTTPS ingress (header/body size limits, Lua, and rate limiting are not supported) |
| **Application Gateway for Containers** | Fully managed L7 outside the cluster (closest to ALB), WAF integration | You need high performance or WAF, or prefer L7 outside the cluster |
| Istio service mesh add-on + Gateway API | Mesh features + ingress | You need mTLS/traffic policies (cannot be used together with App Routing Gateway API) |
| Self-managed (Envoy Gateway, NGINX Gateway Fabric, etc.) | Full control | You need features the managed options do not support |

## Design decisions (best practices)

| Decision | Why |
|---|---|
| Pull the app container **from ACR** (`az acr import`) | Removes the dependency on public registry outages and rate limits, and allows image scanning and auditing. It also verifies the kubelet's `AcrPull` role and the Private Endpoint path directly. |
| Deployment: **requests/limits, probes, non-root, capabilities drop, seccomp, zone spread (best-effort)** | A configuration that passes the Azure Policy baseline (Lab 08) and AKS Automatic's *Deployment Safeguards*. Because zone spread uses `ScheduleAnyway`, pods can pile into one zone when resources are short; `DoNotSchedule` can leave pods stuck in Pending during upgrades or failures, so it was deliberately not chosen. |
| `PodDisruptionBudget` + `HPA(3~10)` | Keeps the app available during node upgrades and drains, and scales automatically with load. |
| NetworkPolicy: **app pods allow only port 8080 from pods in the same namespace (`web`)** | Namespace-level isolation enforced by Cilium. Traffic from the Envoy proxy gets through because the proxy is created in the same namespace. ⚠️ `pod_selector {}` allows *all* pods in `web`. To narrow it down, check the actual labels of the Envoy pods with `kubectl -n web get pods --show-labels` and restrict to those labels. (Apply the NetworkPolicy only to the app pods; otherwise, Envoy's inbound traffic from outside gets blocked.) |
| Namespace PSS: enforce `baseline` + warn on `restricted` | The Envoy proxy pods are created in the same namespace, so enforce stays at baseline. |
| `internal_gateway` variable | Switches between public and internal exposure with a single line of code. In production, the common setup is an internal LB combined with Application Gateway (WAF). |
| Inbound traffic for a public Gateway is allowed in the **03-network node NSG** | A Standard LB blocks inbound traffic by default, and AKS does not add rules to an NSG you attached to the subnet. `AllowGatewayHttpHttps` in 03-network (80/443, source `gateway_allowed_source_prefixes`) fills that role, and for an internal Gateway the default rule (`AllowVnetInBound`) allows traffic from inside the VNet. |

## Code

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

**`app.tf`** — the demo app and the essential production resources (PDB, HPA, NetworkPolicy)

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

**`gateway.tf`** — Gateway and HTTPRoute

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

## Walkthrough

### Step 1. Import the app image into ACR

```bash
ACR=$(terraform -chdir=terraform/04-platform output -raw acr_name)
az acr import -n "$ACR" --source mcr.microsoft.com/dotnet/samples:aspnetapp --image demo/aspnetapp:v1
```

### Step 2. Apply

```bash
cd terraform/07-ingress
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

### Step 3. Verify

```bash
# Is the Gateway Programmed and has it been assigned an address? (1–3 min)
kubectl -n web get gateway,httproute
kubectl -n web get gateway web-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'

# Resources the Gateway created: Envoy Deployment/Service/HPA/PDB
kubectl -n web get deploy,svc,hpa,pdb

# Request
IP=$(kubectl -n web get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')
curl -i "http://$IP/"

# Are the pods spread across zones?
kubectl -n web get pods -l app=aspnetapp -o wide
kubectl -n web get pods -l app=aspnetapp -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c

# Access logs (Envoy enables them by default, single-line JSON). There are 2 Envoy pods, so `deploy/...` would show the logs of only one pod (possibly just startup logs); use the label to see them all
kubectl -n web logs -l gateway.networking.k8s.io/gateway-name=web-gateway --tail=3 --prefix
```

### Step 4. Run behavior experiments

```bash
# (a) Generate load and watch the HPA scale out
kubectl -n web get hpa -w &
kubectl -n web run load --rm -i --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- \
  sh -c 'for i in $(seq 1 3000); do wget -q -O- http://aspnetapp.web.svc.cluster.local/ >/dev/null; done'

# (b) NetworkPolicy: other namespaces cannot reach the app directly
kubectl run np-test --rm -i --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- \
  wget -T 3 -qO- http://aspnetapp.web.svc.cluster.local/ || echo "Blocked (expected behavior)"

# (c) Switch to the internal load balancer → a private IP in snet-ingress
terraform apply -var internal_gateway=true
kubectl -n web get gateway web-gateway -o jsonpath='{.status.addresses[0].value}{"\n"}'   # 10.10.2.x
```

> [!TIP]
> More `kubectl` practice with pods and Deployments (logs, `exec`, `port-forward`, rollouts, troubleshooting) is in [Appendix E](99-appendix.md). This app is managed by Terraform, so do your experiments in a practice namespace: a change made with `kubectl` shows up as a difference in the next `terraform plan` (E-8).

### Extending to TLS (HTTPS)

Add a `443/HTTPS` listener to the `Gateway` and point `tls.certificateRefs` at a Kubernetes Secret. The node NSG (03-network) already allows ports 80 and 443, so you don't need to change the NSG. The Microsoft baseline approach is to **keep the certificate in Key Vault and sync it to a Secret with the Secrets Store CSI driver's `secretObjects`** (the same SecretProviderClass pattern as in Lab 06; the `Key Vault Certificate User` role is required). For the detailed procedure, see [App Routing Gateway API: DNS and TLS](https://learn.microsoft.com/azure/aks/app-routing-gateway-api-dns-tls).

### Automated verification script

It checks Gateway (Programmed) → HTTPRoute (Accepted) → Deployment/HPA/PDB/NetworkPolicy and, for a public Gateway, sends a real `curl` request and expects `200` (skipped for an internal Gateway).

```bash
cd ../..                          # run from the repository root
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

## Common issues

| Symptom | Cause / Fix |
|---|---|
| The `ADDRESS` of the `Gateway` is empty | The LB is still provisioning (1–3 min). Check the Conditions in `kubectl -n web describe gateway web-gateway` and `kubectl -n web get events`. The public IP quota may be exhausted. |
| Plan error `no matches for kind "Gateway"` / no GatewayClass | `azapi_update_resource.gateway_api` from Lab 05 was not applied (check whether `enable_gateway_api=false` was set). Run `kubectl get gatewayclass`. |
| `ImagePullBackOff` | `az acr import` was skipped (image path `demo/aspnetapp:v1`). Check `kubectl describe pod`. |
| `curl` times out | Check that the `AllowGatewayHttpHttps` rule exists on the 03-network node subnet NSG (AKS does not modify an NSG attached to the subnet, so the rule Terraform creates is required) and that your IP is included in `gateway_allowed_source_prefixes`. Other causes: you are accessing an internal Gateway (`internal_gateway=true`) from outside the VNet, or a NetworkPolicy is blocking the traffic. |
| HTTPRoute shows `Accepted: False` | The `parentRefs` name does not match, or `allowedRoutes` (Same namespace) is violated. |

Next → [Lab 08. Governance and security: Azure Policy · Defender · locks · budgets](08-governance.md)
