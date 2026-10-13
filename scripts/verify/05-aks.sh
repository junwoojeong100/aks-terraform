#!/usr/bin/env bash
# Lab 05 검증: AKS 클러스터가 설계한 대로 만들어졌는지 확인합니다 (읽기 전용).
#   1) az aks show 한 번으로 클러스터 설정을 읽습니다 (aws eks describe-cluster 에 해당)
#   2) kubectl 로 노드 · 권한 · 애드온을 확인합니다. kubeconfig 는 임시 파일을 써서 ~/.kube/config 를 건드리지 않습니다.
# 사용법: scripts/verify.sh 05-aks
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready want zones gc pods p bad sku channel netrg podcidr nsgrules
  rg="$(tf_out 05-aks resource_group_name)"
  name="$(tf_out 05-aks cluster_name)"

  section "05-aks · 클러스터 설정 (${name:-?})"
  if [ -z "$name" ]; then
    fail "terraform output 을 읽을 수 없습니다. 05-aks 에서 init/apply 를 마쳤나요?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "클러스터를 찾을 수 없습니다: $name"
    return
  fi

  # --- 상태 ---
  expect_eq "프로비저닝 상태" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "전원 상태" "$(jv "$aks" .powerState.code)" "Running"
  sku="$(jv "$aks" .sku.tier)" # sku_tier 변수: Free / Standard(기본) / Premium
  case "$sku" in
    Standard | Premium) pass "SKU 등급 = $sku (업타임 SLA 포함)" ;;
    Free) warn "SKU 등급 = Free (업타임 SLA 없음. 비용을 줄이려고 sku_tier 를 바꾼 것이 아니라면 Standard 로 올리세요)" ;;
    *) fail "SKU 등급: 기대 Standard 또는 Premium / 실제 '${sku:-(없음)}'" ;;
  esac
  expect_set "Kubernetes 버전" "$(jv "$aks" .currentKubernetesVersion)"

  # --- 보안 / ID ---
  expect_eq "로컬 계정(정적 kubeconfig) 비활성화" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Entra ID 통합 / Azure RBAC" "$(jv "$aks" '[.aadProfile.managed, .aadProfile.enableAzureRbac] | join("/")')" "true/true"
  expect_eq "OIDC issuer (Workload Identity 전제)" "$(jv "$aks" .oidcIssuerProfile.enabled)" "true"
  expect_eq "Workload Identity" "$(jv "$aks" .securityProfile.workloadIdentity.enabled)" "true"

  # --- 네트워크 ---
  expect_eq "CNI / 모드" "$(jv "$aks" '[.networkProfile.networkPlugin, .networkProfile.networkPluginMode] | join("/")')" "azure/overlay"
  expect_eq "데이터 플레인 / 네트워크 정책" "$(jv "$aks" '[.networkProfile.networkDataplane, .networkProfile.networkPolicy] | join("/")')" "cilium/cilium"
  expect_eq "아웃바운드 방식 (직접 만든 NAT Gateway)" "$(jv "$aks" .networkProfile.outboundType)" "userAssignedNATGateway"
  # 03-network 의 노드 NSG 는 Pod CIDR 간 인바운드를 허용합니다 (오버레이 Pod 트래픽에도 서브넷 NSG 가 적용됨).
  # 두 스택의 pod_cidr 가 다르면, 나중에 NSG 에 Deny 규칙을 더하는 순간 노드 간 Pod 통신(DNS 포함)이 막힙니다.
  netrg="$(tf_out 03-network resource_group_name)"
  podcidr="$(jv "$aks" .networkProfile.podCidr)"
  nsgrules=""
  [ -z "$netrg" ] || nsgrules="$(nodes_nsg_rules "$netrg")"
  if [ -z "$nsgrules" ]; then
    skip "03-network 의 노드 NSG 규칙을 읽을 수 없어 Pod CIDR 허용 규칙 확인을 건너뜁니다"
  else
    jq_ok "노드 NSG 가 Pod CIDR(${podcidr}) 간 인바운드를 허용 (03-network 와 05-aks 의 pod_cidr 일치)" "$nsgrules" \
      "any(.[]; .name == \"AllowPodsToPods\" and .access == \"Allow\" and .sourceAddressPrefix == \"$podcidr\" and .destinationAddressPrefix == \"$podcidr\")"
  fi
  expect_eq "API 서버 VNet Integration" "$(jv "$aks" .apiServerAccessProfile.enableVnetIntegration)" "true"
  if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
    pass "프라이빗 클러스터 (API 서버는 VNet 안에서만 접근)"
  else
    jq_ok "API 서버 authorized IP ranges 설정" "$aks" '(.apiServerAccessProfile.authorizedIpRanges | length) >= 1'
  fi

  # --- 업그레이드 / 애드온 ---
  expect_eq "노드 OS 업그레이드 채널" "$(jv "$aks" .autoUpgradeProfile.nodeOsUpgradeChannel)" "NodeImage"
  channel="$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" # 기본 patch. Lab 09 의 A / C-1 방식으로 바꿨다면 다른 값이 정상입니다.
  case "$channel" in
    patch) pass "자동 업그레이드 채널 = patch (기본 구성)" ;;
    none | stable | rapid | node-image) pass "자동 업그레이드 채널 = $channel (기본값 patch 에서 바꾼 값 - Lab 09)" ;;
    *) fail "자동 업그레이드 채널: 기대 patch (또는 none/stable/rapid/node-image) / 실제 '${channel:-(없음)}'" ;;
  esac
  jq_ok "Azure Policy 애드온" "$aks" '.addonProfiles.azurepolicy.enabled == true'
  jq_ok "Container Insights (ama-logs)" "$aks" '.addonProfiles.omsagent.enabled == true or .azureMonitorProfile.containerInsights.enabled == true'
  jq_ok "Key Vault Secrets Store CSI 드라이버" "$aks" '.addonProfiles.azureKeyvaultSecretsProvider.enabled == true'
  jq_ok "Managed Prometheus (ama-metrics)" "$aks" '.azureMonitorProfile.metrics.enabled == true'
  jq_ok "KEDA / VPA" "$aks" '.workloadAutoScalerProfile.keda.enabled == true and .workloadAutoScalerProfile.verticalPodAutoscaler.enabled == true'

  # --- 노드 풀 ---
  jq_ok "System 풀: 오토스케일 + 임시 OS 디스크" "$aks" \
    '.agentPoolProfiles[] | select(.name == "system") | .mode == "System" and .enableAutoScaling == true and .osDiskType == "Ephemeral"'
  jq_ok "User 풀: 오토스케일" "$aks" \
    '.agentPoolProfiles[] | select(.name == "user") | .mode == "User" and .enableAutoScaling == true'
  expect_ge "System 풀 가용 영역 수" "$(jv "$aks" '.agentPoolProfiles[] | select(.name == "system") | .availabilityZones | length')" 2

  # --- kubectl ---
  section "05-aks · kubectl 확인"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 'Azure Kubernetes Service Cluster User Role' 역할을 확인하세요)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
      skip "프라이빗 클러스터의 API 서버에 접속할 수 없어 kubectl 확인을 건너뜁니다 (VNet 안의 점프 호스트·VPN 에서 다시 실행하세요)"
    else
      fail "API 서버에 접속하지 못했습니다. 공인 IP 가 바뀌었다면 TF_VAR_allowed_ip_ranges 를 갱신하고 05-aks 를 apply 하세요."
    fi
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  # 오토스케일 풀은 minCount 아래로 내려가지 않으므로, 풀별 최소 노드 수의 합(기본 system 3 + user 3)을 기준으로 삼습니다.
  want="$(jv "$aks" '[.agentPoolProfiles[] | if .enableAutoScaling == true then (.minCount // 0) else (.count // 0) end] | add')"
  expect_ge "Ready 노드 수 (풀별 최소 노드 수의 합)" "$ready" "${want:-1}"
  zones="$(jv "$nodes" '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')"
  expect_ge "노드가 분산된 가용 영역 수" "$zones" 2

  if [ "$(kubectl --request-timeout=20s auth can-i '*' '*' 2>/dev/null)" = "yes" ]; then
    pass "cluster-admin 권한 (Azure RBAC Cluster Admin)"
  else
    fail "cluster-admin 권한이 없습니다 (역할 전파에 최대 5분, grant_current_user_admin / admin_principal_ids 확인)"
  fi

  if [ "$(jv "$aks" '(.ingressProfile.gatewayApi // .ingressProfile.gatewayAPI // {}).installation')" = "Standard" ]; then
    gc="$(kj get gatewayclass approuting-istio)"
    jq_ok "GatewayClass approuting-istio 가 Accepted" "$gc" '.status.conditions[]? | select(.type == "Accepted") | .status == "True"'
  else
    skip "Gateway API 가 꺼져 있어 GatewayClass 확인을 건너뜁니다 (enable_gateway_api = false)"
  fi

  pods="$(kj get pods -n kube-system)"
  for p in ama-logs ama-metrics cilium coredns; do
    jq_ok "kube-system: $p 파드 Running" "$pods" "[.items[] | select((.metadata.name | startswith(\"$p\")) and .status.phase == \"Running\")] | length >= 1"
  done
  bad="$(kj get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded)"
  jq_warn "Running/Completed 가 아닌 파드가 없음" "$bad" '(.items | length) == 0'
}

# 직접 실행(scripts/verify/05-aks.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
