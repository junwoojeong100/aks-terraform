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
