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
