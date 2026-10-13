#!/usr/bin/env bash
# Lab 06 검증: Workload Identity(IRSA 에 해당)와 Key Vault CSI 가 끝까지 연결되었는지 확인합니다 (읽기 전용).
#   Azure 쪽  : 앱 UAMI ← Federated credential(issuer + subject) ← Key Vault Secrets User 역할
#   쿠버네티스: ServiceAccount annotation → 파드 label → 주입된 환경 변수 → 마운트된 시크릿
# 사용법: scripts/verify.sh 06-workload
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local client_id ns rg aks_name kv kv_id uami uami_name uami_rg uami_pid fic subject sa sa_json dep
  client_id="$(tf_out 06-workload app_identity_client_id)"
  ns="$(tf_out 06-workload namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"
  kv="$(tf_out 04-platform key_vault_name)"

  section "06-workload · Azure 쪽 (UAMI · Federated credential · 역할)"
  if [ -z "$client_id" ]; then
    fail "terraform output 을 읽을 수 없습니다. 06-workload 에서 init/apply 를 마쳤나요?"
    return
  fi

  # client ID 로 구독 안의 UAMI 를 찾습니다.
  uami="$(jv "$(azj identity list)" "[.[] | select(.clientId == \"$client_id\")][0]")"
  uami_name="$(jv "$uami" .name)"
  uami_rg="$(jv "$uami" .resourceGroup)"
  uami_pid="$(jv "$uami" .principalId)"
  expect_set "앱 UAMI" "$uami_name"
  [ -n "$uami_name" ] || return

  fic="$(azj identity federated-credential list --identity-name "$uami_name" -g "$uami_rg")"
  subject="$(jv "$fic" '[.[].subject | select(startswith("system:serviceaccount:"))][0]')"
  sa="${subject##*:}"
  sa="${sa:-${TF_VAR_app_service_account:-workload-sa}}" # federated credential 이 없으면 기본 이름으로 계속 확인합니다.
  expect_eq "Federated credential subject 의 네임스페이스" "${subject%:*}" "system:serviceaccount:$ns"
  expect_eq "Federated credential issuer = 클러스터 OIDC issuer" "$(jv "$fic" '.[0].issuer')" "$(tf_out 05-aks oidc_issuer_url)"

  kv_id="$(az keyvault show -n "$kv" --query id -o tsv 2>/dev/null)"
  has_role "앱 UAMI → Key Vault Secrets User (읽기 전용 최소 권한)" "$uami_pid" "Key Vault Secrets User" "$kv_id"

  section "06-workload · 쿠버네티스 쪽 (ServiceAccount · 파드 · 시크릿 마운트)"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 Cluster User Role 확인)"
    return
  fi

  sa_json="$(kj get serviceaccount "$sa" -n "$ns")"
  expect_eq "ServiceAccount 의 client-id annotation (IRSA 의 role-arn 에 해당)" \
    "$(jv "$sa_json" '.metadata.annotations["azure.workload.identity/client-id"]')" "$client_id"

  dep="$(kj get deployment kv-demo -n "$ns")"
  jq_ok "Deployment kv-demo 준비됨" "$dep" '(.status.readyReplicas // 0) >= 1'
  expect_eq "파드 label azure.workload.identity/use (webhook 주입 조건)" \
    "$(jv "$dep" '.spec.template.metadata.labels["azure.workload.identity/use"]')" "true"

  # 파드 안에서 확인: webhook 이 주입한 환경 변수, CSI 로 마운트된 시크릿 파일 (값은 출력하지 않습니다)
  expect_eq "파드에 주입된 AZURE_CLIENT_ID" \
    "$(kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- printenv AZURE_CLIENT_ID 2>/dev/null)" "$client_id"
  if kubectl --request-timeout=30s -n "$ns" exec deploy/kv-demo -- test -s /mnt/secrets-store/demo-secret 2>/dev/null; then
    pass "Key Vault 시크릿이 파드에 마운트됨 (/mnt/secrets-store/demo-secret)"
  else
    fail "시크릿 파일이 없거나 비어 있습니다 (kubectl -n $ns describe pod 의 이벤트에서 마운트 오류 확인)"
  fi
}

# 직접 실행(scripts/verify/06-workload.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
