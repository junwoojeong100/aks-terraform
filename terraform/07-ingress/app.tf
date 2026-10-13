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

          security_context {
            allow_privilege_escalation = false

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
