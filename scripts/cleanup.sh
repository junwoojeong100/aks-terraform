#!/usr/bin/env bash
# 실습 리소스를 "생성의 역순"으로 삭제합니다 (Lab 11 의 절차를 자동화).
#   10-aks-automatic → 08-governance → 07-ingress → 06-workload → 05-aks → 04-platform → 03-network   (+ 02-bootstrap 은 옵션)
#   06/07 은 클러스터가 살아 있어야 kubernetes provider 가 접속해 지울 수 있으므로 05 보다 먼저 지웁니다.
#
# 사용법:
#   scripts/cleanup.sh --dry-run                 # 아무것도 지우지 않고 할 일만 출력 (먼저 이것부터!)
#   scripts/cleanup.sh                           # 'delete' 를 입력해 확인한 뒤 03~10 스택 삭제
#   scripts/cleanup.sh --yes 05-aks 04-platform  # 지정한 스택만, 질문 없이
#   scripts/cleanup.sh --include-bootstrap       # 02-bootstrap(state 저장소)까지 삭제 (로컬 state 로 되돌린 경우만)
#
# 필요: terraform, az(로그인), terraform/backend.hcl, 환경 변수 ARM_SUBSCRIPTION_ID · TF_VAR_allowed_ip_ranges (apply 때와 같은 값)
# 이미 지운 스택은 건너뛰므로, 중간에 실패해도 원인을 해결한 뒤 같은 명령을 다시 실행하면 됩니다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"
cd "$ROOT" || exit 2

STACK_ORDER="10-aks-automatic 08-governance 07-ingress 06-workload 05-aks 04-platform 03-network" # 삭제 순서
yes=0
dry=0
bootstrap=0
requested=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y | --yes) yes=1 ;;
    -n | --dry-run) dry=1 ;;
    --include-bootstrap) bootstrap=1 ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "알 수 없는 옵션: $1 (--help 참고)" >&2
      exit 2
      ;;
    *) requested="$requested $1" ;;
  esac
  shift
done

for r in $requested; do
  case " $STACK_ORDER " in
    *" $r "*) ;;
    *)
      echo "알 수 없는 스택: $r (사용 가능: $STACK_ORDER)" >&2
      exit 2
      ;;
  esac
done

# 지정한 스택을 항상 "삭제 순서"대로 정렬합니다 (순서를 바꿔 입력해도 안전).
targets=""
for s in $STACK_ORDER; do
  if [ -z "$requested" ] || printf ' %s ' "$requested" | grep -q " $s "; then targets="$targets $s"; fi
done
[ "$bootstrap" -eq 1 ] && targets="$targets 02-bootstrap"

# --- 실행 도우미 ---------------------------------------------------------------
# run 명령... : 명령을 보여 주고 실행합니다 (dry-run 이면 보여 주기만).
run() {
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  [ "$dry" -eq 1 ] || "$@"
}

# run_quiet 명령... : 출력은 숨기고, 실패했을 때만 출력을 보여 줍니다 (init 처럼 시끄러운 명령용).
run_quiet() {
  local out
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  [ "$dry" -eq 1 ] && return 0
  out="$("$@" 2>&1)" || {
    printf '%s\n' "$out"
    return 1
  }
}

tf_init() { run_quiet terraform -chdir="terraform/$1" init -backend-config=../backend.hcl -input=false -no-color; }
tf_state() { terraform -chdir="terraform/$1" state list 2>/dev/null; }

# 05-aks state 에 클러스터가 없으면(= 이미 지움) 0
cluster_gone() {
  [ "$dry" -eq 1 ] && return 1
  tf_init 05-aks >/dev/null 2>&1 || return 1
  ! tf_state 05-aks | grep -q '^azurerm_kubernetes_cluster\.this$'
}

# 클러스터가 이미 없으면 kubernetes provider 가 접속할 수 없으므로, 안에 있던 리소스는 state 에서만 제거합니다.
drop_k8s_state_if_cluster_gone() {
  local res
  cluster_gone || return 0
  warn "$1: 클러스터가 이미 없습니다 → 쿠버네티스 리소스를 state 에서 제거한 뒤 Azure 리소스만 삭제합니다"
  # 파일 디스크립터 3 으로 목록을 읽어, terraform 이 표준 입력을 가져가지 못하게 합니다.
  while IFS= read -r res <&3; do
    run terraform -chdir="terraform/$1" state rm "$res"
  done 3< <(tf_state "$1" | grep -E '^kubernetes_')
}

# 08 이 건 리소스 잠금(CanNotDelete)이 있으면 destroy 가 ScopeLocked 로 실패하므로 먼저 해제합니다.
# apply -var enable_resource_locks=false 는 정책 효과·Defender 같은 다른 설정까지 되돌리므로,
# 잠금 리소스만 -target 으로 지웁니다 (08 스택의 나머지는 그대로 두었다가 순서에 맞춰 destroy).
unlock_resource_locks() {
  section "리소스 잠금 해제 (08-governance)"
  if ! tf_init 08-governance; then
    warn "08-governance 를 초기화하지 못해 잠금 확인을 건너뜁니다"
    return 0
  fi
  local unlock=(terraform -chdir=terraform/08-governance destroy -auto-approve -input=false -lock-timeout=300s -no-color
    -target=azurerm_management_lock.network -target=azurerm_management_lock.platform)
  if [ "$dry" -eq 1 ]; then
    info "(잠금이 있을 때만 실행됩니다)"
    run "${unlock[@]}"
  elif tf_state 08-governance | grep -q '^azurerm_management_lock\.'; then
    run "${unlock[@]}" || return 1
  else
    skip "해제할 잠금이 없습니다"
  fi
}

destroy_stack() {
  local s="$1"
  section "destroy $s"
  if [ ! -d "terraform/$s" ]; then
    skip "스택 디렉터리가 없습니다"
    return 0
  fi
  tf_init "$s" || {
    fail "$s: init 실패 (terraform/backend.hcl 과 ARM_SUBSCRIPTION_ID 를 확인하세요)"
    return 1
  }
  if [ "$dry" -eq 0 ] && [ -z "$(tf_state "$s")" ]; then
    skip "$s: state 가 비어 있습니다 (이미 삭제됨)"
    return 0
  fi
  case "$s" in 06-workload | 07-ingress) drop_k8s_state_if_cluster_gone "$s" ;; esac
  if run terraform -chdir="terraform/$s" destroy -auto-approve -input=false -lock-timeout=300s -no-color; then
    if [ "$dry" -eq 1 ]; then info "(dry-run) 실제로 실행하면 $s 스택이 삭제됩니다"; else pass "$s 삭제 완료"; fi
  else
    fail "$s: destroy 실패 → 위 오류를 해결한 뒤 같은 명령을 다시 실행하세요 (이미 지운 스택은 건너뜁니다)"
    case "$s" in
      06-workload | 07-ingress) info "API 서버에 접속하지 못했다면 공인 IP 가 바뀐 경우가 많습니다. TF_VAR_allowed_ip_ranges 를 갱신하고 05-aks 를 apply 하세요." ;;
      03-network | 04-platform)
        info "ScopeLocked 오류라면 CanNotDelete 잠금이 남아 있는 것입니다 (08 의 잠금은 이 스크립트가 먼저 해제합니다)."
        info "확인: az lock list -o table  →  직접 만든 잠금 삭제: az lock delete -n <잠금 이름> -g <리소스 그룹>"
        ;;
    esac
    return 1
  fi
}

# 02-bootstrap 은 state 가 담긴 저장소 자체이므로, 로컬 state 로 되돌린 경우에만 지웁니다.
destroy_bootstrap() {
  section "destroy 02-bootstrap (state 저장소)"
  if grep -Eq '^[[:space:]]*backend "azurerm"' terraform/02-bootstrap/versions.tf; then
    fail "02-bootstrap 의 state 가 아직 원격(Blob)에 있습니다. 자기 자신이 담긴 저장소는 지울 수 없으므로 먼저 로컬로 되돌리세요:"
    info "1) terraform/02-bootstrap/versions.tf 의 backend \"azurerm\" 블록을 다시 주석 처리"
    info "2) terraform -chdir=terraform/02-bootstrap init -migrate-state -force-copy"
    info "3) 이 스크립트를 --include-bootstrap 으로 다시 실행"
    return 1
  fi
  run_quiet terraform -chdir=terraform/02-bootstrap init -input=false -no-color || return 1
  if run terraform -chdir=terraform/02-bootstrap destroy -auto-approve -input=false -no-color; then
    run rm -f terraform/backend.hcl
    if [ "$dry" -eq 1 ]; then info "(dry-run) 실제로 실행하면 02-bootstrap 이 삭제됩니다"; else pass "02-bootstrap 삭제 완료"; fi
  else
    fail "02-bootstrap: destroy 실패"
    return 1
  fi
}

report_leftovers() {
  local rgs nodes kvs
  section "정리 확인"
  rgs="$(az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv 2>/dev/null)"
  nodes="$(az group list --query "[?contains(name,'-aks-nodes') || (starts_with(name,'MC_') && contains(name,'-automatic_'))].name" -o tsv 2>/dev/null)"
  kvs="$(az keyvault list-deleted --query '[].name' -o tsv 2>/dev/null)"
  if [ -z "$rgs" ]; then
    pass "태그 lab=aks-terraform-guide 리소스 그룹이 없습니다"
  else
    warn "남아 있는 리소스 그룹: $(printf '%s' "$rgs" | tr '\n' ' ')"
    info "그래도 지워지지 않으면(Terraform 을 다시 쓸 계획이 없을 때만): az group delete -n <이름> --yes --no-wait"
  fi
  [ -z "$nodes" ] || warn "AKS 노드 리소스 그룹이 남아 있습니다: $(printf '%s' "$nodes" | tr '\n' ' ') (클러스터 삭제 후 몇 분 뒤 사라집니다)"
  info "soft-delete 상태의 Key Vault: ${kvs:-없음} (purge protection 이면 7일간 이름만 점유하며 비용은 없습니다)"
}

# --- 시작 -----------------------------------------------------------------------
section "삭제 계획"
if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
  info "구독: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"
fi
for s in $targets; do info "- $s"; done
[ "$dry" -eq 1 ] && info "dry-run: 실제로는 아무것도 삭제하지 않습니다."

if [ "$dry" -eq 0 ]; then
  require_cmd terraform az || exit 2
  az account show >/dev/null 2>&1 || {
    echo "az login 이 필요합니다." >&2
    exit 2
  }
  [ -n "${ARM_SUBSCRIPTION_ID:-}" ] || {
    echo "ARM_SUBSCRIPTION_ID 가 설정되어 있지 않습니다 (Lab 01)." >&2
    exit 2
  }
  [ "$ARM_SUBSCRIPTION_ID" = "$(az account show --query id -o tsv)" ] || {
    echo "ARM_SUBSCRIPTION_ID 와 az 의 현재 구독이 다릅니다. 지울 구독을 확인하세요." >&2
    exit 2
  }
  [ -n "${TF_VAR_allowed_ip_ranges:-}" ] || {
    echo "TF_VAR_allowed_ip_ranges 가 설정되어 있지 않습니다 (apply 때와 같은 값)." >&2
    exit 2
  }
  [ -f terraform/backend.hcl ] || {
    echo "terraform/backend.hcl 이 없습니다 (Lab 02 에서 만든 파일)." >&2
    exit 2
  }
  if [ "$yes" -eq 0 ]; then
    printf '\n위 스택의 리소스가 모두 삭제됩니다. 계속하려면 %sdelete%s 를 입력하세요: ' "$C_BLD" "$C_OFF"
    read -r answer
    [ "$answer" = "delete" ] || {
      echo "취소했습니다."
      exit 1
    }
  fi
fi

case " $targets " in
  *" 08-governance "* | *" 04-platform "* | *" 03-network "*) unlock_resource_locks || fail "잠금 해제 실패" ;;
esac

for s in $targets; do
  if [ "$s" = "02-bootstrap" ]; then destroy_bootstrap || break; else destroy_stack "$s" || break; fi
done

if [ "$dry" -eq 1 ]; then
  printf '\n%sdry-run 이 끝났습니다. 실제로 삭제하려면 --dry-run 없이 다시 실행하세요.%s\n' "$C_BLD" "$C_OFF"
  [ "$FAIL" -eq 0 ]
  exit
fi

report_leftovers
summary
