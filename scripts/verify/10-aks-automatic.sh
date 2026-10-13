#!/usr/bin/env bash
# Lab 10 verification: checks that the AKS Automatic cluster was created in the "we operate it for you" mode (read-only).
#   AWS comparison: EKS Auto Mode (the cloud manages nodes · scaling · upgrades · security defaults)
# Usage: scripts/verify.sh 10-aks-automatic
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready pools
  rg="$(tf_out 10-aks-automatic resource_group_name)"
  name="$(tf_out 10-aks-automatic cluster_name)"

  section "10-aks-automatic · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 10-aks-automatic?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "SKU (name / tier)" "$(jv "$aks" '[.sku.name, .sku.tier] | join("/")')" "Automatic/Standard"
  expect_eq "Node provisioning (NAP = Karpenter-based)" "$(jv "$aks" .nodeProvisioningProfile.mode)" "Auto"
  expect_eq "Local accounts disabled (Azure RBAC only)" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Azure RBAC" "$(jv "$aks" .aadProfile.enableAzureRbac)" "true"
  expect_eq "CNI / data plane" "$(jv "$aks" '[.networkProfile.networkPluginMode, .networkProfile.networkDataplane] | join("/")')" "overlay/cilium"
  expect_eq "Auto-upgrade channel" "$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" "stable"
  expect_eq "OIDC issuer / Workload Identity" "$(jv "$aks" '[.oidcIssuerProfile.enabled, .securityProfile.workloadIdentity.enabled] | join("/")')" "true/true"

  section "10-aks-automatic · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply."
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  expect_ge "Ready nodes (managed system pool)" "$ready" 1

  # NAP creates nodes through Karpenter NodePools (the same concept as NodePools in EKS Auto Mode).
  pools="$(kj get nodepools.karpenter.sh)"
  jq_warn "Karpenter NodePool exists (NAP)" "$pools" '(.items | length) >= 1'
}

# You can also run it directly (scripts/verify/10-aks-automatic.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
