#!/usr/bin/env bash
# Lab 08 verification: checks Azure Policy assignments · compliance state · Defender · resource locks (read-only).
#   AWS comparison: AWS Config/SCP + Security Hub/GuardDuty + resource deletion protection (termination protection)
#   Policies default to Audit (report only), so non-compliant resources are shown only as a "warning".
# Usage: scripts/verify.sh 08-governance
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg names n a state tier g count
  rg="$(tf_out 05-aks resource_group_name)"
  names="$(terraform -chdir="${TF_DIR}/08-governance" output -json policy_assignments 2>/dev/null | jq -r '.[]?' 2>/dev/null)"

  section "08-governance · policy assignments (${rg:-?})"
  if [ -z "$names" ]; then
    fail "Can't read the policy_assignments output. Did you finish init/apply in 08-governance?"
    return
  fi
  for n in $names; do
    a="$(azj policy assignment show -n "$n" -g "$rg")"
    expect_set "Policy assignment $n" "$(jv "$a" .displayName)"
  done

  # Compliance evaluation can take up to tens of minutes right after assignment.
  # Even with non-compliant resources, Audit mode doesn't block deployments.
  state="$(azj policy state summarize -g "$rg")"
  if [ -z "$state" ]; then
    warn "Can't query the compliance state yet (right after assignment, evaluation may not have run)"
  else
    jq_warn "No non-compliant resources (currently $(jv "$state" '.results.nonCompliantResources // 0'))" "$state" '(.results.nonCompliantResources // 0) == 0'
  fi

  section "08-governance · Defender · locks"
  tier="$(az security pricing show -n Containers --query pricingTier -o tsv 2>/dev/null)"
  if [ "$tier" = "Standard" ]; then
    pass "Defender for Containers subscription plan is on"
  else
    info "Defender for Containers subscription plan: ${tier:-unknown} (default: enable_defender_plan = false)"
  fi
  for g in "$(tf_out 03-network resource_group_name)" "$(tf_out 04-platform resource_group_name)"; do
    [ -n "$g" ] || continue
    count="$(az lock list -g "$g" --query 'length(@)' -o tsv 2>/dev/null)"
    info "Resource locks in $g: ${count:-0} (default: enable_resource_locks = false)"
  done
}

# You can also run it directly (scripts/verify/08-governance.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
