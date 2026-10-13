#!/usr/bin/env bash
# Lab 04 검증: ACR · Key Vault · Log Analytics · Prometheus/Grafana · AKS 용 ID 와 역할 할당을 확인합니다 (읽기 전용).
#   AWS 비교: ECR · KMS/Secrets Manager · CloudWatch Logs · Managed Prometheus/Grafana · IAM Role + 정책
# 사용법: scripts/verify.sh 04-platform
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Private Endpoint 연결이 1개 이상이고 모두 Approved 인가 (az 버전에 따라 JSON 중첩이 달라 둘 다 허용)
PE_APPROVED='[.[]? | (.privateLinkServiceConnectionState // .properties.privateLinkServiceConnectionState).status] | length >= 1 and all(.[]; . == "Approved")'

verify_stack() {
  local rg net_rg acr kv law_id law_name amw_id grafana acr_json kv_json law amw
  local id_cluster id_kubelet cluster_pid kubelet_pid net_rg_id
  rg="$(tf_out 04-platform resource_group_name)"
  net_rg="$(tf_out 03-network resource_group_name)"
  acr="$(tf_out 04-platform acr_name)"
  kv="$(tf_out 04-platform key_vault_name)"
  law_id="$(tf_out 04-platform log_analytics_workspace_id)"
  amw_id="$(tf_out 04-platform monitor_workspace_id)"
  grafana="$(tf_out 04-platform grafana_endpoint)"
  id_cluster="$(tf_out 04-platform aks_cluster_identity)"
  id_kubelet="$(tf_out 04-platform aks_kubelet_identity)"

  section "04-platform · 플랫폼 서비스 (${rg:-?})"
  if [ -z "$rg" ]; then
    fail "terraform output 을 읽을 수 없습니다. 04-platform 에서 init/apply 를 마쳤나요?"
    return
  fi

  # --- ACR (ECR) ---
  acr_json="$(azj acr show -g "$rg" -n "$acr")"
  expect_eq "ACR SKU (Private Endpoint 는 Premium 필요)" "$(jv "$acr_json" .sku.name)" "Premium"
  expect_eq "ACR 관리자 계정(admin user) 사용" "$(jv "$acr_json" .adminUserEnabled)" "false"
  expect_eq "ACR 익명 pull 허용" "$(jv "$acr_json" .anonymousPullEnabled)" "false"
  expect_eq "ACR 공용 접근 기본 동작 (방화벽)" "$(jv "$acr_json" .networkRuleSet.defaultAction)" "Deny"
  jq_ok "ACR Private Endpoint 승인됨" "$acr_json" ".privateEndpointConnections | $PE_APPROVED"

  # --- Key Vault (KMS + Secrets Manager) ---
  kv_json="$(azj keyvault show -n "$kv")"
  expect_eq "Key Vault 권한 모델 = Azure RBAC" "$(jv "$kv_json" .properties.enableRbacAuthorization)" "true"
  expect_eq "Key Vault 공용 접근 기본 동작 (방화벽)" "$(jv "$kv_json" .properties.networkAcls.defaultAction)" "Deny"
  jq_warn "Key Vault purge protection 켜짐 (운영 권장)" "$kv_json" '.properties.enablePurgeProtection == true'
  jq_ok "Key Vault Private Endpoint 승인됨" "$kv_json" ".properties.privateEndpointConnections | $PE_APPROVED"

  # --- 관측성 ---
  law_name="${law_id##*/}"
  law="$(azj monitor log-analytics workspace show -g "$rg" -n "$law_name")"
  expect_eq "Log Analytics 로컬(공유 키) 인증 차단" "$(jv "$law" .features.disableLocalAuth)" "true"
  expect_set "Log Analytics 보존 기간(일)" "$(jv "$law" .retentionInDays)"
  amw="$(azj resource show --ids "$amw_id")"
  expect_eq "Azure Monitor workspace(Managed Prometheus) 상태" "$(jv "$amw" .properties.provisioningState)" "Succeeded"
  if [ -n "$grafana" ]; then
    pass "Managed Grafana: $grafana"
  else
    skip "Managed Grafana 없음 (enable_grafana = false)"
  fi

  # --- AKS 용 Managed Identity 와 역할 할당 (IAM Role + 정책 연결에 해당) ---
  cluster_pid="$(jv "$(azj identity show -g "$rg" -n "$id_cluster")" .principalId)"
  kubelet_pid="$(jv "$(azj identity show -g "$rg" -n "$id_kubelet")" .principalId)"
  expect_set "컨트롤 플레인 UAMI ($id_cluster)" "$cluster_pid"
  expect_set "kubelet UAMI ($id_kubelet)" "$kubelet_pid"
  net_rg_id="$(az group show -n "$net_rg" --query id -o tsv 2>/dev/null)"
  if [ -n "$kubelet_pid" ] && [ -n "$cluster_pid" ]; then
    has_role "kubelet → AcrPull (ACR)" "$kubelet_pid" "AcrPull" "$(jv "$acr_json" .id)"
    has_role "컨트롤 플레인 → Network Contributor (네트워크 RG)" "$cluster_pid" "Network Contributor" "$net_rg_id"
  fi
}

# 직접 실행(scripts/verify/04-platform.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
