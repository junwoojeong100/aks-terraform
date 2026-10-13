#!/usr/bin/env bash
# Common functions shared by the verify and cleanup scripts. Don't run it directly; source it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"      # from scripts/verify/*.sh
#
# Contents: result output (pass/fail/warn), value comparison (expect_*), JSON helpers (jq),
# and wrappers for terraform output / az / kubectl.
# Works with the default macOS bash (3.2), so newer syntax such as associative arrays is not used.
# shellcheck shell=bash

# Load only once, even if sourced several times.
[ -n "${_AKS_LAB_COMMON_LOADED:-}" ] && return 0
_AKS_LAB_COMMON_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- Result output ------------------------------------------------------------
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

# Call once at the end. Exit code 1 if there is at least one failure.
summary() {
  printf '\n%sSummary%s  passed %s%d%s · failed %s%d%s · warnings %d · skipped %d\n' \
    "$C_BLD" "$C_OFF" "$C_GRN" "$PASS" "$C_OFF" "$C_RED" "$FAIL" "$C_OFF" "$WARN" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# --- Value comparison ---------------------------------------------------------
expect_eq() { # description actual expected
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: expected '$3' / actual '${2:-(none)}'"; fi
}

expect_set() { # description value  (fails if empty or null)
  if [ -n "$2" ] && [ "$2" != "null" ]; then pass "$1: $2"; else fail "$1: no value"; fi
}

expect_ge() { # description actual minimum
  if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then pass "$1: $2 (min $3)"; else fail "$1: expected at least $3 / actual '${2:-(none)}'"; fi
}

jq_ok() { # description json jq-condition  → passes if the condition is true
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else fail "$1"; fi
}

jq_warn() { # description json jq-condition  → warns if the condition is false (for items that are recommended, not required)
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else warn "$1"; fi
}

# --- JSON / external command wrappers -----------------------------------------
# jv JSON 'jq-filter' : extracts a value as a string (null becomes an empty string; empty input is not an error)
jv() {
  jq -r "($2) | if . == null then \"\" else tostring end" <<<"$1" 2>/dev/null
}

# azj <az args...> : runs az with JSON output. Returns an empty string on failure
# (so the script doesn't stop when a resource doesn't exist).
azj() { az "$@" -o json 2>/dev/null || true; }

# kj <kubectl args...> : gets kubectl output as JSON. Gives up after 20 seconds even if the API server doesn't respond.
kj() { kubectl --request-timeout=20s "$@" -o json 2>/dev/null || true; }

# tf_out stack output-name : terraform output -raw (empty string if there is no value or apply hasn't run yet)
tf_out() { terraform -chdir="${TF_DIR}/$1" output -raw "$2" 2>/dev/null || true; }

# nodes_nsg_rules network-resource-group : gets the rules of the 03-network node subnet NSG (…-aks-nodes) as JSON
#   (empty string if there is no NSG)
nodes_nsg_rules() {
  local nsg
  nsg="$(az network nsg list -g "$1" --query "[?ends_with(name, '-aks-nodes')].name | [0]" -o tsv 2>/dev/null)"
  [ -n "$nsg" ] || return 0
  azj network nsg rule list -g "$1" --nsg-name "$nsg"
}

# tf_applied stack : returns 0 if there is at least one output (= init and apply are done)
tf_applied() {
  local out
  out="$(terraform -chdir="${TF_DIR}/$1" output -json 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != "{}" ]
}

# has_role description principalId role-name scope-prefix
#   Passes if the principal has the role assigned at or below that scope (case-insensitive).
#   AWS comparison: "is a policy attached to the IAM Role?" → in Azure, an assignment has three parts:
#   "principal + role + scope".
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

# require_cmd command... : returns 0 if all exist; otherwise prints a message and returns 1
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "Required command not found: $c" >&2; missing=1; }
  done
  return "$missing"
}

# version_ge current minimum : returns 0 if the current version >= the minimum version (e.g. version_ge 1.16.5 1.16)
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

# --- kubectl access -----------------------------------------------------------
# kube_login resource-group cluster
#   Creates a temporary kubeconfig for this script and points KUBECONFIG at it (your ~/.kube/config is not modified).
#   Does the same as `az aks get-credentials` + `kubelogin convert-kubeconfig` from Lab 05.
kube_login() {
  [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP" # Remove the previous temp file when verifying several stacks.
  _KUBECONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/aks-lab-kubeconfig.XXXXXX")"
  export KUBECONFIG="$_KUBECONFIG_TMP"
  az aks get-credentials -g "$1" -n "$2" --file "$KUBECONFIG" --overwrite-existing >/dev/null 2>&1 &&
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
}

_aks_lab_cleanup() { [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP"; }
trap _aks_lab_cleanup EXIT
