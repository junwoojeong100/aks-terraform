#!/usr/bin/env bash
# Lab 07 검증: Gateway API 로 노출한 웹 앱이 정상 동작하는지 확인합니다 (읽기 전용).
#   Gateway(Programmed) → HTTPRoute(Accepted) → Service → Pod, 그리고 PDB · HPA · NetworkPolicy
# 사용법: scripts/verify.sh 07-ingress
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local ns rg aks_name gw addr route dep code i
  ns="$(tf_out 07-ingress namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"

  section "07-ingress · Gateway API (${ns:-?})"
  if [ -z "$ns" ]; then
    fail "terraform output 을 읽을 수 없습니다. 07-ingress 에서 init/apply 를 마쳤나요?"
    return
  fi
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 Cluster User Role 확인)"
    return
  fi

  # istio 등 다른 CRD 와 이름이 겹치지 않도록 API 그룹까지 적습니다.
  gw="$(kj get gateway.gateway.networking.k8s.io web-gateway -n "$ns")"
  jq_ok "Gateway web-gateway 가 Programmed" "$gw" '.status.conditions[]? | select(.type == "Programmed") | .status == "True"'
  addr="$(jv "$gw" '.status.addresses[0].value')"
  expect_set "Gateway 에 할당된 로드밸런서 주소" "$addr"

  route="$(kj get httproute.gateway.networking.k8s.io aspnetapp -n "$ns")"
  jq_ok "HTTPRoute aspnetapp 이 Accepted" "$route" '.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status == "True"'

  dep="$(kj get deployment aspnetapp -n "$ns")"
  jq_ok "Deployment aspnetapp: 준비된 레플리카 = 원하는 수" "$dep" '(.status.readyReplicas // 0) == .spec.replicas and .spec.replicas >= 1'
  jq_ok "HPA aspnetapp 존재" "$(kj get hpa aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "PodDisruptionBudget aspnetapp 존재" "$(kj get pdb aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "NetworkPolicy 존재 (같은 네임스페이스에서 오는 트래픽만 허용)" \
    "$(kj get networkpolicy aspnetapp-allow-same-namespace -n "$ns")" '.metadata.name == "aspnetapp-allow-same-namespace"'

  # 실제 요청: 내부(사설 IP) Gateway 는 VNet 밖에서 접근할 수 없으므로 건너뜁니다.
  if printf '%s' "$addr" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
    skip "내부 Gateway($addr)는 VNet 안에서만 접근할 수 있어 curl 을 건너뜁니다"
  elif [ -n "$addr" ]; then
    code=""
    for i in 1 2 3 4 5 6; do # 방금 만든 로드밸런서는 응답까지 1분 정도 걸릴 수 있습니다.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$addr/" 2>/dev/null || true)"
      [ "$code" = "200" ] && break
      [ "$i" -lt 6 ] && sleep 10
    done
    expect_eq "GET http://$addr/ 응답 코드" "$code" "200"
  fi
}

# 직접 실행(scripts/verify/07-ingress.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
