#!/usr/bin/env bash
# 실습 시작 전 점검 (읽기 전용): 도구 · 로그인 · 환경 변수 · Resource Provider · vCPU 쿼터 · VM 크기 · 권한
# Lab 01 의 확인 절차를 한 번에 실행합니다. 아무것도 만들거나 바꾸지 않습니다.
#
# 사용법:
#   scripts/preflight.sh
#   LOCATION=japaneast scripts/preflight.sh      # 다른 리전 (기본: TF_VAR_location 또는 koreacentral)
#
# 종료 코드: 실패 항목이 없으면 0, 있으면 1
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

LOCATION="${LOCATION:-${TF_VAR_location:-koreacentral}}"
VM_SIZE="${VM_SIZE:-Standard_D4ds_v5}"
VM_FAMILY="${VM_FAMILY:-standardDDSv5Family}" # VM_SIZE 를 바꿨다면 `az vm list-usage` 의 패밀리 이름으로 함께 바꾸세요.
MIN_VCPU=24                                   # 기본 구성의 최소 노드 6대 x 4 vCPU
REC_VCPU=40                                   # 업그레이드 임시 노드(surge)와 오토스케일 여유까지
RESOURCE_PROVIDERS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault
Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor Microsoft.Dashboard
Microsoft.AlertsManagement Microsoft.ManagedIdentity Microsoft.PolicyInsights Microsoft.Security Microsoft.Authorization
Microsoft.Consumption Microsoft.CostManagement"

# need 명령 최소버전 설치안내 : 명령이 있고 버전이 충분한지 확인
need() {
  local cmd="$1" min="$2" hint="$3" ver=""
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$cmd 가 없습니다 → $hint"
    return
  fi
  case "$cmd" in
    terraform) ver="$(terraform version 2>/dev/null | sed -n '1s/^Terraform v//p')" ;;
    az) ver="$(az version --query '"azure-cli"' -o tsv 2>/dev/null)" ;;
    kubectl) ver="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)" ;;
  esac
  if [ -n "$min" ] && [ -n "$ver" ]; then
    if version_ge "$ver" "$min"; then pass "$cmd $ver (최소 $min)"; else fail "$cmd $ver → 최소 $min 필요: $hint"; fi
  else
    pass "$cmd${ver:+ $ver}"
  fi
}

# check_quota 이름 여유vCPU
check_quota() {
  if [ -z "$2" ]; then
    warn "$1: 조회하지 못했습니다 (az vm list-usage -l $LOCATION)"
  elif [ "$2" -lt "$MIN_VCPU" ]; then
    fail "$1 여유 $2 vCPU → 최소 $MIN_VCPU 필요 (포털 → 구독 → 사용량 + 할당량 에서 증설)"
  elif [ "$2" -lt "$REC_VCPU" ]; then
    warn "$1 여유 $2 vCPU (업그레이드 임시 노드까지 고려하면 $REC_VCPU 권장)"
  else
    pass "$1 여유 $2 vCPU"
  fi
}

section "1. 도구"
need terraform 1.16 "brew install hashicorp/tap/terraform (또는 tfenv)"
need az 2.86 "brew install azure-cli"
need kubectl "" "az aks install-cli"
need kubelogin "" "az aks install-cli"
need jq "" "brew install jq  /  sudo apt install jq   (검증 스크립트가 사용)"
need curl "" "OS 패키지 관리자로 설치"

section "2. Azure 로그인"
acct=""
if command -v az >/dev/null 2>&1; then acct="$(azj account show)"; fi
if [ -z "$acct" ]; then
  fail "로그인되어 있지 않습니다 → az login"
  summary
  exit 1
fi
sub_id="$(jv "$acct" .id)"
pass "구독: $(jv "$acct" .name) ($sub_id)"
info "테넌트 $(jv "$acct" .tenantId) · 로그인 $(jv "$acct" .user.name)"

section "3. 환경 변수"
if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
  fail "ARM_SUBSCRIPTION_ID 가 없습니다 → export ARM_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
elif [ "$ARM_SUBSCRIPTION_ID" != "$sub_id" ]; then
  warn "ARM_SUBSCRIPTION_ID($ARM_SUBSCRIPTION_ID)가 현재 az 구독($sub_id)과 다릅니다"
else
  pass "ARM_SUBSCRIPTION_ID 가 현재 구독과 일치합니다"
fi
if [ -z "${TF_VAR_allowed_ip_ranges:-}" ]; then
  fail "TF_VAR_allowed_ip_ranges 가 없습니다 → export TF_VAR_allowed_ip_ranges='[\"<내 공인 IP>/32\"]'"
elif jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$"))' \
  >/dev/null 2>&1 <<<"$TF_VAR_allowed_ip_ranges"; then
  pass "TF_VAR_allowed_ip_ranges = $TF_VAR_allowed_ip_ranges"
else
  fail "TF_VAR_allowed_ip_ranges 형식 오류 (CIDR 문자열의 JSON 배열이어야 합니다): $TF_VAR_allowed_ip_ranges"
fi
if [ -n "${TF_VAR_workload:-}" ]; then
  if printf '%s' "$TF_VAR_workload" | grep -Eq '^[a-z0-9]{3,8}$'; then pass "TF_VAR_workload = $TF_VAR_workload"; else fail "TF_VAR_workload 는 소문자/숫자 3–8자여야 합니다: $TF_VAR_workload"; fi
fi

section "4. Resource Provider 등록 (azurerm 5.x 는 자동 등록하지 않습니다)"
registered="$(az provider list --query "[?registrationState=='Registered'].namespace" -o tsv 2>/dev/null)"
missing=""
for rp in $RESOURCE_PROVIDERS; do
  printf '%s\n' "$registered" | grep -qix "$rp" || missing="$missing $rp"
done
if [ -z "$missing" ]; then
  pass "필요한 Resource Provider 모두 등록됨"
else
  fail "미등록:$missing"
  info "등록: for rp in$missing; do az provider register --namespace \$rp; done   (1–5분 소요)"
fi

section "5. vCPU 쿼터 ($LOCATION)"
usage="$(azj vm list-usage -l "$LOCATION")"
check_quota "$VM_FAMILY 패밀리" "$(jv "$usage" ".[] | select(.name.value == \"$VM_FAMILY\") | (.limit | tonumber) - (.currentValue | tonumber)")"
check_quota "리전 전체(Total Regional vCPUs)" "$(jv "$usage" '.[] | select(.name.value == "cores") | (.limit | tonumber) - (.currentValue | tonumber)')"

section "6. VM 크기 ($VM_SIZE @ $LOCATION)"
skus="$(azj vm list-skus -l "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines)"
sku="$(jv "$skus" "[.[] | select(.name == \"$VM_SIZE\")][0]")"
if [ -z "$sku" ] || [ "$sku" = "null" ]; then
  fail "$VM_SIZE 를 $LOCATION 에서 찾을 수 없습니다 (다른 크기/리전을 쓰려면 Lab 05 의 *_node_vm_size, location 변수를 바꾸세요)"
else
  zones="$(jv "$sku" '[.locationInfo[0].zones[]?] | sort | join(",")')"
  if [ "$zones" = "1,2,3" ]; then pass "가용 영역 1,2,3 모두 사용 가능"; else warn "사용 가능한 영역: ${zones:-없음} (var.zones 를 이에 맞게 줄이세요)"; fi
  if [ "$(jv "$sku" '[.restrictions[]?] | length')" = "0" ]; then pass "구독 제한(restrictions) 없음"; else fail "이 구독에서 $VM_SIZE 사용이 제한되어 있습니다 (restrictions)"; fi
fi

section "7. 권한 (이 실습은 역할 할당을 많이 만듭니다)"
# 게스트/개인(MSA) 계정은 로그인 이름(user.name)으로 조회가 안 되므로 객체 ID 를 우선 씁니다 (서비스 주체는 appId 로 대체).
me="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"
[ -n "$me" ] || me="$(jv "$acct" .user.name)"
roles="$(az role assignment list --assignee "$me" --all --include-inherited --query '[].roleDefinitionName' -o tsv 2>/dev/null)"
if printf '%s\n' "$roles" | grep -qx 'Owner'; then
  pass "Owner 역할 보유"
elif printf '%s\n' "$roles" | grep -qx 'Contributor' && printf '%s\n' "$roles" | grep -qxE 'User Access Administrator|Role Based Access Control Administrator'; then
  pass "Contributor + 역할 할당 권한 보유"
elif [ -z "$roles" ]; then
  warn "역할을 조회하지 못했습니다 (그룹으로 받은 권한은 보이지 않을 수 있음). 포털 → 구독 → 액세스 제어(IAM)에서 확인하세요."
else
  warn "Owner 또는 Contributor + User Access Administrator 가 필요합니다. 확인된 역할: $(printf '%s' "$roles" | tr '\n' ',')"
fi

summary
