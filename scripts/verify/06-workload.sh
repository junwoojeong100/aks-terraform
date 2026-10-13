#!/usr/bin/env bash
# Lab 06 verification: checks that Workload Identity (the equivalent of IRSA) and the Key Vault CSI driver
# are connected end to end (read-only).
#   Azure side : app UAMI ← Federated credential (issuer + subject) ← Key Vault Secrets User role
#   Kubernetes : ServiceAccount annotation → pod label → injected environment variable → mounted secret
# Usage: scripts/verify.sh 06-workload
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local client_id ns rg aks_name kv kv_id uami uami_name uami_rg uami_pid fic subject sa sa_json dep
  client_id="$(tf_out 06-workload app_identity_client_id)"
  ns="$(tf_out 06-workload namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"
  kv="$(tf_out 04-platform key_vault_name)"

  section "06-workload · Azure side (UAMI · Federated credential · role)"
  if [ -z "$client_id" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 06-workload?"
    return
  fi

  # Find the UAMI in the subscription by its client ID.
  uami="$(jv "$(azj identity list)" "[.[] | select(.clientId == \"$client_id\")][0]")"
  uami_name="$(jv "$uami" .name)"
  uami_rg="$(jv "$uami" .resourceGroup)"
  uami_pid="$(jv "$uami" .principalId)"
  expect_set "App UAMI" "$uami_name"
  [ -n "$uami_name" ] || return

  fic="$(azj identity federated-credential list --identity-name "$uami_name" -g "$uami_rg")"
  subject="$(jv "$fic" '[.[].subject | select(startswith("system:serviceaccount:"))][0]')"
  sa="${subject##*:}"
  sa="${sa:-${TF_VAR_app_service_account:-workload-sa}}" # If there is no federated credential, keep checking with the default name.
  expect_eq "Namespace in the Federated credential subject" "${subject%:*}" "system:serviceaccount:$ns"
  expect_eq "Federated credential issuer = cluster OIDC issuer" "$(jv "$fic" '.[0].issuer')" "$(tf_out 05-aks oidc_issuer_url)"

  kv_id="$(az keyvault show -n "$kv" --query id -o tsv 2>/dev/null)"
  has_role "App UAMI → Key Vault Secrets User (least privilege, read-only)" "$uami_pid" "Key Vault Secrets User" "$kv_id"

  section "06-workload · Kubernetes side (ServiceAccount · pod · secret mount)"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi

  sa_json="$(kj get serviceaccount "$sa" -n "$ns")"
  expect_eq "ServiceAccount client-id annotation (the equivalent of IRSA's role-arn)" \
    "$(jv "$sa_json" '.metadata.annotations["azure.workload.identity/client-id"]')" "$client_id"

  dep="$(kj get deployment kv-demo -n "$ns")"
  jq_ok "Deployment kv-demo is ready" "$dep" '(.status.readyReplicas // 0) >= 1'
  expect_eq "Pod label azure.workload.identity/use (condition for webhook injection)" \
    "$(jv "$dep" '.spec.template.metadata.labels["azure.workload.identity/use"]')" "true"

  # Check inside the pod: the environment variable injected by the webhook and the secret file mounted
  # by the CSI driver (values are not printed)
  expect_eq "AZURE_CLIENT_ID injected into the pod" \
    "$(kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- printenv AZURE_CLIENT_ID 2>/dev/null)" "$client_id"
  if kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- test -s /mnt/secrets-store/demo-secret 2>/dev/null; then
    pass "Key Vault secret mounted in the pod (/mnt/secrets-store/demo-secret)"
  else
    fail "Secret file is missing or empty (look for mount errors in the events of kubectl -n $ns describe pod)"
  fi
}

# You can also run it directly (scripts/verify/06-workload.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
