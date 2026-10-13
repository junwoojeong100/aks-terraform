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
