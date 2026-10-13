#!/usr/bin/env bash
# Lab 08 검증: Azure Policy 할당 · 준수 상태 · Defender · 리소스 잠금을 확인합니다 (읽기 전용).
#   AWS 비교: AWS Config/SCP + Security Hub/GuardDuty + 리소스 삭제 방지(termination protection)
#   정책은 기본값이 Audit(보고만)이라 비준수 리소스가 있어도 "경고"로만 표시합니다.
# 사용법: scripts/verify.sh 08-governance
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg names n a state tier g count
  rg="$(tf_out 05-aks resource_group_name)"
  names="$(terraform -chdir="${TF_DIR}/08-governance" output -json policy_assignments 2>/dev/null | jq -r '.[]?' 2>/dev/null)"

  section "08-governance · 정책 할당 (${rg:-?})"
  if [ -z "$names" ]; then
    fail "policy_assignments 출력을 읽을 수 없습니다. 08-governance 에서 init/apply 를 마쳤나요?"
    return
  fi
  for n in $names; do
    a="$(azj policy assignment show -n "$n" -g "$rg")"
    expect_set "정책 할당 $n" "$(jv "$a" .displayName)"
  done

  # 준수 평가는 할당 직후 최대 수십 분이 걸립니다. 비준수가 있어도 Audit 모드면 배포는 막지 않습니다.
  state="$(azj policy state summarize -g "$rg")"
  if [ -z "$state" ]; then
    warn "준수 상태를 아직 조회할 수 없습니다 (할당 직후에는 평가 전일 수 있습니다)"
  else
    jq_warn "비준수 리소스가 없음 (현재 $(jv "$state" '.results.nonCompliantResources // 0')개)" "$state" '(.results.nonCompliantResources // 0) == 0'
  fi

  section "08-governance · Defender · 잠금"
  tier="$(az security pricing show -n Containers --query pricingTier -o tsv 2>/dev/null)"
  if [ "$tier" = "Standard" ]; then
    pass "Defender for Containers 구독 플랜 켜짐"
  else
    info "Defender for Containers 구독 플랜: ${tier:-확인 불가} (enable_defender_plan = false 가 기본값)"
  fi
  for g in "$(tf_out 03-network resource_group_name)" "$(tf_out 04-platform resource_group_name)"; do
    [ -n "$g" ] || continue
    count="$(az lock list -g "$g" --query 'length(@)' -o tsv 2>/dev/null)"
    info "리소스 잠금 $g: ${count:-0}개 (enable_resource_locks = false 가 기본값)"
  done
}

# 직접 실행(scripts/verify/08-governance.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
