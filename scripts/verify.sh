#!/usr/bin/env bash
# 실습 결과 검증 (읽기 전용): 각 스택이 설계한 대로 만들어졌는지 az / kubectl 로 확인합니다.
# 이름은 스택의 `terraform output` 에서 찾으므로, 그 스택에서 init + apply 를 마친 뒤 실행하세요.
#
# 사용법:
#   scripts/verify.sh                       # apply 한 모든 스택 (아직 안 한 스택은 건너뜀)
#   scripts/verify.sh 05-aks                # 특정 스택만
#   scripts/verify.sh 03-network 04-platform
#
# 필요: terraform, az(로그인), jq   (05 이후: kubectl, kubelogin)
# 종료 코드: 모두 통과 0 / 실패가 있으면 1 / 사용법 오류 2
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

ALL_STACKS="02-bootstrap 03-network 04-platform 05-aks 06-workload 07-ingress 08-governance 10-aks-automatic"

case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

require_cmd terraform az jq || exit 2
if ! az account show >/dev/null 2>&1; then
  echo "az login 이 필요합니다." >&2
  exit 2
fi

explicit=0
stacks="$ALL_STACKS"
if [ "$#" -gt 0 ]; then
  explicit=1
  stacks="$*"
fi
for s in $stacks; do
  case " $ALL_STACKS " in
    *" $s "*) ;;
    *)
      echo "알 수 없는 스택: $s (사용 가능: $ALL_STACKS)" >&2
      exit 2
      ;;
  esac
done

info "구독: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"

for s in $stacks; do
  if ! tf_applied "$s"; then
    section "$s"
    if [ "$explicit" -eq 1 ]; then
      fail "아직 apply 하지 않았거나 init 이 필요합니다 (terraform -chdir=terraform/$s init -backend-config=../backend.hcl)"
    else
      skip "아직 apply 하지 않은 스택이라 건너뜁니다"
    fi
    continue
  fi
  # shellcheck source=/dev/null
  source "${HERE}/verify/${s}.sh"
  verify_stack
done

summary
