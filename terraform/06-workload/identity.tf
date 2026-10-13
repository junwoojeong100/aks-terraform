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
