#!/usr/bin/env bash
# Lab 04 verification: checks ACR · Key Vault · Log Analytics · Prometheus/Grafana · the identities for AKS
# and their role assignments (read-only).
#   AWS comparison: ECR · KMS/Secrets Manager · CloudWatch Logs · Managed Prometheus/Grafana · IAM Role + policies
# Usage: scripts/verify.sh 04-platform
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Is there at least one Private Endpoint connection, and are all of them Approved?
# (the JSON nesting differs by az version, so both shapes are accepted)
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

  section "04-platform · platform services (${rg:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 04-platform?"
    return
  fi

  # --- ACR (ECR) ---
  acr_json="$(azj acr show -g "$rg" -n "$acr")"
  expect_eq "ACR SKU (Private Endpoint requires Premium)" "$(jv "$acr_json" .sku.name)" "Premium"
  expect_eq "ACR admin user enabled" "$(jv "$acr_json" .adminUserEnabled)" "false"
  expect_eq "ACR anonymous pull allowed" "$(jv "$acr_json" .anonymousPullEnabled)" "false"
  expect_eq "ACR default action for public access (firewall)" "$(jv "$acr_json" .networkRuleSet.defaultAction)" "Deny"
  jq_ok "ACR Private Endpoint approved" "$acr_json" ".privateEndpointConnections | $PE_APPROVED"

  # --- Key Vault (KMS + Secrets Manager) ---
  kv_json="$(azj keyvault show -n "$kv")"
  expect_eq "Key Vault permission model = Azure RBAC" "$(jv "$kv_json" .properties.enableRbacAuthorization)" "true"
  expect_eq "Key Vault default action for public access (firewall)" "$(jv "$kv_json" .properties.networkAcls.defaultAction)" "Deny"
  jq_warn "Key Vault purge protection on (recommended for production)" "$kv_json" '.properties.enablePurgeProtection == true'
  jq_ok "Key Vault Private Endpoint approved" "$kv_json" ".properties.privateEndpointConnections | $PE_APPROVED"

  # --- Observability ---
  law_name="${law_id##*/}"
  law="$(azj monitor log-analytics workspace show -g "$rg" -n "$law_name")"
  expect_eq "Log Analytics local (shared key) auth disabled" "$(jv "$law" .features.disableLocalAuth)" "true"
  expect_set "Log Analytics retention (days)" "$(jv "$law" .retentionInDays)"
  amw="$(azj resource show --ids "$amw_id")"
  expect_eq "Azure Monitor workspace (Managed Prometheus) state" "$(jv "$amw" .properties.provisioningState)" "Succeeded"
  if [ -n "$grafana" ]; then
    pass "Managed Grafana: $grafana"
  else
    skip "No Managed Grafana (enable_grafana = false)"
  fi

  # --- Managed Identities for AKS and their role assignments (equivalent to an IAM Role + attached policies) ---
  cluster_pid="$(jv "$(azj identity show -g "$rg" -n "$id_cluster")" .principalId)"
  kubelet_pid="$(jv "$(azj identity show -g "$rg" -n "$id_kubelet")" .principalId)"
  expect_set "Control plane UAMI ($id_cluster)" "$cluster_pid"
  expect_set "kubelet UAMI ($id_kubelet)" "$kubelet_pid"
  net_rg_id="$(az group show -n "$net_rg" --query id -o tsv 2>/dev/null)"
  if [ -n "$kubelet_pid" ] && [ -n "$cluster_pid" ]; then
    has_role "kubelet → AcrPull (ACR)" "$kubelet_pid" "AcrPull" "$(jv "$acr_json" .id)"
    has_role "Control plane → Network Contributor (network RG)" "$cluster_pid" "Network Contributor" "$net_rg_id"
  fi
}

# You can also run it directly (scripts/verify/04-platform.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
