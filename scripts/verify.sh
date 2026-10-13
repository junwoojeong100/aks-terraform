#!/usr/bin/env bash
# Lab results verification (read-only): checks with az / kubectl that each stack was built as designed.
# Names are looked up from each stack's `terraform output`, so run this after init + apply in that stack.
#
# Usage:
#   scripts/verify.sh                       # every applied stack (stacks not applied yet are skipped)
#   scripts/verify.sh 05-aks                # one stack only
#   scripts/verify.sh 03-network 04-platform
#
# Requires: terraform, az (signed in), jq   (from 05 on: kubectl, kubelogin)
# Exit codes: 0 = all passed / 1 = any failure / 2 = usage error
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
  echo "az login is required." >&2
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
      echo "Unknown stack: $s (available: $ALL_STACKS)" >&2
      exit 2
      ;;
  esac
done

info "Subscription: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"

for s in $stacks; do
  if ! tf_applied "$s"; then
    section "$s"
    if [ "$explicit" -eq 1 ]; then
      fail "Not applied yet, or init is required (terraform -chdir=terraform/$s init -backend-config=../backend.hcl)"
    else
      skip "Stack not applied yet; skipping"
    fi
    continue
  fi
  # shellcheck source=/dev/null
  source "${HERE}/verify/${s}.sh"
  verify_stack
done

summary
