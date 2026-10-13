#!/usr/bin/env bash
# 모든 Terraform 스택을 Azure 자격 증명/구독 없이 정적 검증합니다.
#   fmt -check  →  init -backend=false  →  validate  →  terraform test (mock provider)
#   (modules/naming 은 provider 가 없으므로 terraform test 만 실행)
#
# 사용법:
#   tools/validate-all.sh              # 전체 스택
#   tools/validate-all.sh 05-aks       # 특정 스택만
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/terraform"

export CHECKPOINT_DISABLE=1
export TF_IN_AUTOMATION=1

if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  stacks=()
  for d in [0-9][0-9]-*/; do
    stacks+=("${d%/}")
  done
fi

terraform version | head -1

echo
echo "== modules/naming (fmt, validate, test)"
terraform -chdir=modules/naming fmt -check -diff
terraform -chdir=modules/naming init -backend=false -input=false -no-color >/dev/null
terraform -chdir=modules/naming validate -no-color
terraform -chdir=modules/naming test -no-color

for stack in "${stacks[@]}"; do
  echo
  echo "== ${stack}"
  terraform -chdir="${stack}" fmt -check -diff
  terraform -chdir="${stack}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${stack}" validate -no-color
  # Azure 없이 mock provider 로 plan 로직(변수 검증, count/for_each, 조건식)을 검증합니다.
  terraform -chdir="${stack}" test -no-color
done

echo
echo "All checks passed."
