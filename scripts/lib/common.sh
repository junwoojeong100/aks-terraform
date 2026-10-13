#!/usr/bin/env bash
# 검증·정리 스크립트가 함께 쓰는 공통 함수입니다. 직접 실행하지 않고 source 해서 씁니다.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"      # scripts/verify/*.sh 에서
#
# 들어 있는 것: 결과 출력(pass/fail/warn), 값 비교(expect_*), JSON 헬퍼(jq), terraform output / az / kubectl 래퍼.
# macOS 기본 bash(3.2)에서도 동작하도록 연관 배열 같은 최신 문법은 쓰지 않았습니다.
# shellcheck shell=bash

# 여러 번 source 해도 한 번만 로드합니다.
[ -n "${_AKS_LAB_COMMON_LOADED:-}" ] && return 0
_AKS_LAB_COMMON_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- 결과 출력 ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_DIM=''; C_OFF=''
fi

PASS=0; FAIL=0; WARN=0; SKIP=0

section() { printf '\n%s== %s%s\n' "$C_BLD" "$*" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*"; }
warn() { WARN=$((WARN + 1)); printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  %s-%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# 마지막에 한 번 호출합니다. 실패가 하나라도 있으면 종료 코드 1.
summary() {
  printf '\n%s요약%s  통과 %s%d%s · 실패 %s%d%s · 경고 %d · 건너뜀 %d\n' \
    "$C_BLD" "$C_OFF" "$C_GRN" "$PASS" "$C_OFF" "$C_RED" "$FAIL" "$C_OFF" "$WARN" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# --- 값 비교 -----------------------------------------------------------------
expect_eq() { # 설명 실제값 기대값
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: 기대 '$3' / 실제 '${2:-(없음)}'"; fi
}

expect_set() { # 설명 값  (비어 있거나 null 이면 실패)
  if [ -n "$2" ] && [ "$2" != "null" ]; then pass "$1: $2"; else fail "$1: 값이 없습니다"; fi
}

expect_ge() { # 설명 실제값 최소값
  if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then pass "$1: $2 (최소 $3)"; else fail "$1: 최소 $3 필요 / 실제 '${2:-(없음)}'"; fi
}

jq_ok() { # 설명 JSON jq조건  → 조건이 참이면 통과
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else fail "$1"; fi
}

jq_warn() { # 설명 JSON jq조건  → 조건이 거짓이면 경고 (필수는 아니지만 권장인 항목)
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else warn "$1"; fi
}

# --- JSON / 외부 명령 래퍼 -----------------------------------------------------
# jv JSON 'jq필터' : 값을 문자열로 꺼냅니다 (null 은 빈 문자열, 입력이 비어 있어도 오류 없음)
jv() {
  jq -r "($2) | if . == null then \"\" else tostring end" <<<"$1" 2>/dev/null
}

# azj <az 인자...> : az 를 JSON 으로 실행합니다. 실패하면 빈 문자열 (리소스가 없을 때도 스크립트가 멈추지 않게).
azj() { az "$@" -o json 2>/dev/null || true; }

# kj <kubectl 인자...> : kubectl 결과를 JSON 으로 가져옵니다. API 서버가 응답하지 않아도 20초 뒤 포기합니다.
kj() { kubectl --request-timeout=20s "$@" -o json 2>/dev/null || true; }

# tf_out 스택 출력이름 : terraform output -raw (값이 없거나 apply 전이면 빈 문자열)
tf_out() { terraform -chdir="${TF_DIR}/$1" output -raw "$2" 2>/dev/null || true; }

# tf_applied 스택 : 출력이 하나라도 있으면(= init 과 apply 를 마쳤으면) 0
tf_applied() {
  local out
  out="$(terraform -chdir="${TF_DIR}/$1" output -json 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != "{}" ]
}

# has_role 설명 principalId 역할이름 scope접두사
#   이 주체에게 해당 범위(scope) 아래로 역할이 할당되어 있으면 통과합니다 (대소문자 무시).
#   AWS 비교: "IAM Role 에 정책이 붙어 있는가" → Azure 는 "주체 + 역할 + 범위" 세 요소의 할당입니다.
has_role() {
  local roles
  roles="$(azj role assignment list --assignee "$2" --all)"
  if jq -e --arg role "$3" --arg scope "$4" \
    'any(.[]; .roleDefinitionName == $role and ((.scope | ascii_downcase) | startswith($scope | ascii_downcase)))' \
    >/dev/null 2>&1 <<<"$roles"; then
    pass "$1"
  else
    fail "$1"
  fi
}

# require_cmd 명령... : 모두 있으면 0, 없으면 안내를 출력하고 1
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "필요한 명령이 없습니다: $c" >&2; missing=1; }
  done
  return "$missing"
}

# version_ge 현재 최소 : 현재 버전 >= 최소 버전 이면 0 (예: version_ge 1.16.5 1.16)
version_ge() {
  local -a a b
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  local i x y
  for i in 0 1 2; do
    x="${a[$i]:-0}"; y="${b[$i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}

# --- kubectl 접속 ---------------------------------------------------------------
# kube_login 리소스그룹 클러스터
#   이 스크립트 전용 임시 kubeconfig 를 만들어 KUBECONFIG 로 지정합니다 (내 ~/.kube/config 는 수정하지 않습니다).
#   Lab 05 에서 한 `az aks get-credentials` + `kubelogin convert-kubeconfig` 와 같은 동작입니다.
kube_login() {
  [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP" # 여러 스택을 검증할 때 이전 임시 파일을 지웁니다.
  _KUBECONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/aks-lab-kubeconfig.XXXXXX")"
  export KUBECONFIG="$_KUBECONFIG_TMP"
  az aks get-credentials -g "$1" -n "$2" --file "$KUBECONFIG" --overwrite-existing >/dev/null 2>&1 &&
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
}

_aks_lab_cleanup() { [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP"; }
trap _aks_lab_cleanup EXIT
