#!/usr/bin/env bash
# Lab 07 verification: checks that the web app exposed through the Gateway API works (read-only).
#   Gateway (Programmed) → HTTPRoute (Accepted) → Service → Pod, plus PDB · HPA · NetworkPolicy
# Usage: scripts/verify.sh 07-ingress
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local ns rg aks_name gw addr route dep code i
  ns="$(tf_out 07-ingress namespace)"
  rg="$(tf_out 05-aks resource_group_name)"
  aks_name="$(tf_out 05-aks cluster_name)"

  section "07-ingress · Gateway API (${ns:-?})"
  if [ -z "$ns" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 07-ingress?"
    return
  fi
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$aks_name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi

  # Spell out the API group so that the name doesn't clash with other CRDs such as istio's.
  gw="$(kj get gateway.gateway.networking.k8s.io web-gateway -n "$ns")"
  jq_ok "Gateway web-gateway is Programmed" "$gw" '.status.conditions[]? | select(.type == "Programmed") | .status == "True"'
  addr="$(jv "$gw" '.status.addresses[0].value')"
  expect_set "Load balancer address assigned to the Gateway" "$addr"

  route="$(kj get httproute.gateway.networking.k8s.io aspnetapp -n "$ns")"
  jq_ok "HTTPRoute aspnetapp is Accepted" "$route" '.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status == "True"'

  dep="$(kj get deployment aspnetapp -n "$ns")"
  jq_ok "Deployment aspnetapp: ready replicas = desired replicas" "$dep" '(.status.readyReplicas // 0) == .spec.replicas and .spec.replicas >= 1'
  jq_ok "HPA aspnetapp exists" "$(kj get hpa aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "PodDisruptionBudget aspnetapp exists" "$(kj get pdb aspnetapp -n "$ns")" '.metadata.name == "aspnetapp"'
  jq_ok "NetworkPolicy exists (allows only traffic from the same namespace)" \
    "$(kj get networkpolicy aspnetapp-allow-same-namespace -n "$ns")" '.metadata.name == "aspnetapp-allow-same-namespace"'

  # Real request: an internal (private IP) Gateway can't be reached from outside the VNet, so skip it.
  if printf '%s' "$addr" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
    skip "Internal Gateway ($addr) is reachable only from inside the VNet; skipping curl"
  elif [ -n "$addr" ]; then
    code=""
    for i in 1 2 3 4 5 6; do # A load balancer that was just created can take about a minute to respond.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$addr/" 2>/dev/null || true)"
      [ "$code" = "200" ] && break
      [ "$i" -lt 6 ] && sleep 10
    done
    expect_eq "GET http://$addr/ response code" "$code" "200"
  fi
}

# You can also run it directly (scripts/verify/07-ingress.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
