#!/usr/bin/env bash
# Lab 10 검증: AKS Automatic 클러스터가 "운영까지 맡기는" 모드로 만들어졌는지 확인합니다 (읽기 전용).
#   AWS 비교: EKS Auto Mode (노드 · 스케일링 · 업그레이드 · 보안 기본값을 클라우드가 관리)
# 사용법: scripts/verify.sh 10-aks-automatic
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready pools
  rg="$(tf_out 10-aks-automatic resource_group_name)"
  name="$(tf_out 10-aks-automatic cluster_name)"

  section "10-aks-automatic · 클러스터 설정 (${name:-?})"
  if [ -z "$name" ]; then
    fail "terraform output 을 읽을 수 없습니다. 10-aks-automatic 에서 init/apply 를 마쳤나요?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "클러스터를 찾을 수 없습니다: $name"
    return
  fi

  expect_eq "프로비저닝 상태" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "SKU (이름 / 등급)" "$(jv "$aks" '[.sku.name, .sku.tier] | join("/")')" "Automatic/Standard"
  expect_eq "노드 프로비저닝 (NAP = Karpenter 기반)" "$(jv "$aks" .nodeProvisioningProfile.mode)" "Auto"
  expect_eq "로컬 계정 비활성화 (Azure RBAC 만 사용)" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Azure RBAC" "$(jv "$aks" .aadProfile.enableAzureRbac)" "true"
  expect_eq "CNI / 데이터 플레인" "$(jv "$aks" '[.networkProfile.networkPluginMode, .networkProfile.networkDataplane] | join("/")')" "overlay/cilium"
  expect_eq "자동 업그레이드 채널" "$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" "stable"
  expect_eq "OIDC issuer / Workload Identity" "$(jv "$aks" '[.oidcIssuerProfile.enabled, .securityProfile.workloadIdentity.enabled] | join("/")')" "true/true"

  section "10-aks-automatic · kubectl 확인"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 Cluster User Role 확인)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    fail "API 서버에 접속하지 못했습니다. 공인 IP 가 바뀌었다면 TF_VAR_allowed_ip_ranges 를 갱신하고 apply 하세요."
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  expect_ge "Ready 노드 수 (관리형 system 풀)" "$ready" 1

  # NAP 는 Karpenter 의 NodePool 로 노드를 만듭니다 (EKS Auto Mode 의 NodePool 과 같은 개념).
  pools="$(kj get nodepools.karpenter.sh)"
  jq_warn "Karpenter NodePool 이 있음 (NAP)" "$pools" '(.items | length) >= 1'
}

# 직접 실행(scripts/verify/10-aks-automatic.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
