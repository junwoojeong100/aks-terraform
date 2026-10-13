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
