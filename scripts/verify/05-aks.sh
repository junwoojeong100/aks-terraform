#!/usr/bin/env bash
# Lab 05 verification: checks that the AKS cluster was created as designed (read-only).
#   1) A single `az aks show` reads the cluster settings (the equivalent of aws eks describe-cluster)
#   2) kubectl checks nodes · permissions · add-ons. kubeconfig is a temporary file, so ~/.kube/config is left alone.
# Usage: scripts/verify.sh 05-aks
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready want zones gc pods p bad sku channel netrg podcidr nsgrules
  rg="$(tf_out 05-aks resource_group_name)"
  name="$(tf_out 05-aks cluster_name)"

  section "05-aks · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 05-aks?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  # --- Status ---
  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "Power state" "$(jv "$aks" .powerState.code)" "Running"
  sku="$(jv "$aks" .sku.tier)" # sku_tier variable: Free / Standard (default) / Premium
  case "$sku" in
    Standard | Premium) pass "SKU tier = $sku (includes uptime SLA)" ;;
    Free) warn "SKU tier = Free (no uptime SLA. Unless you changed sku_tier to cut costs, raise it to Standard)" ;;
    *) fail "SKU tier: expected Standard or Premium / actual '${sku:-(none)}'" ;;
  esac
  expect_set "Kubernetes version" "$(jv "$aks" .currentKubernetesVersion)"

  # --- Security / identity ---
  expect_eq "Local accounts (static kubeconfig) disabled" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Entra ID integration / Azure RBAC" "$(jv "$aks" '[.aadProfile.managed, .aadProfile.enableAzureRbac] | join("/")')" "true/true"
  expect_eq "OIDC issuer (prerequisite for Workload Identity)" "$(jv "$aks" .oidcIssuerProfile.enabled)" "true"
  expect_eq "Workload Identity" "$(jv "$aks" .securityProfile.workloadIdentity.enabled)" "true"

  # --- Networking ---
  expect_eq "CNI / mode" "$(jv "$aks" '[.networkProfile.networkPlugin, .networkProfile.networkPluginMode] | join("/")')" "azure/overlay"
  expect_eq "Data plane / network policy" "$(jv "$aks" '[.networkProfile.networkDataplane, .networkProfile.networkPolicy] | join("/")')" "cilium/cilium"
  expect_eq "Outbound type (your own NAT Gateway)" "$(jv "$aks" .networkProfile.outboundType)" "userAssignedNATGateway"
  # The 03-network node NSG allows inbound traffic between Pod CIDRs (the subnet NSG also applies to overlay Pod traffic).
  # If the two stacks' pod_cidr values differ, adding a Deny rule to the NSG later would block Pod-to-Pod
  # traffic between nodes (including DNS).
  netrg="$(tf_out 03-network resource_group_name)"
  podcidr="$(jv "$aks" .networkProfile.podCidr)"
  nsgrules=""
  [ -z "$netrg" ] || nsgrules="$(nodes_nsg_rules "$netrg")"
  if [ -z "$nsgrules" ]; then
    skip "Can't read the 03-network node NSG rules; skipping the Pod CIDR allow-rule check"
  else
    jq_ok "Node NSG allows inbound within the Pod CIDR ${podcidr} (pod_cidr is the same in 03-network and 05-aks)" "$nsgrules" \
      "any(.[]; .name == \"AllowPodsToPods\" and .access == \"Allow\" and .sourceAddressPrefix == \"$podcidr\" and .destinationAddressPrefix == \"$podcidr\")"
  fi
  expect_eq "API server VNet Integration" "$(jv "$aks" .apiServerAccessProfile.enableVnetIntegration)" "true"
  if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
    pass "Private cluster (API server reachable only from inside the VNet)"
  else
    jq_ok "API server authorized IP ranges set" "$aks" '(.apiServerAccessProfile.authorizedIpRanges | length) >= 1'
  fi

  # --- Upgrades / add-ons ---
  expect_eq "Node OS upgrade channel" "$(jv "$aks" .autoUpgradeProfile.nodeOsUpgradeChannel)" "NodeImage"
  channel="$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" # Default: patch. Other values are expected after Lab 09 approach A / C-1.
  case "$channel" in
    patch) pass "Auto-upgrade channel = patch (default setup)" ;;
    none | stable | rapid | node-image) pass "Auto-upgrade channel = $channel (changed from the default value patch - Lab 09)" ;;
    *) fail "Auto-upgrade channel: expected patch (or none/stable/rapid/node-image) / actual '${channel:-(none)}'" ;;
  esac
  jq_ok "Azure Policy add-on" "$aks" '.addonProfiles.azurepolicy.enabled == true'
  jq_ok "Container Insights (ama-logs)" "$aks" '.addonProfiles.omsagent.enabled == true or .azureMonitorProfile.containerInsights.enabled == true'
  jq_ok "Key Vault Secrets Store CSI driver" "$aks" '.addonProfiles.azureKeyvaultSecretsProvider.enabled == true'
  jq_ok "Managed Prometheus (ama-metrics)" "$aks" '.azureMonitorProfile.metrics.enabled == true'
  jq_ok "KEDA / VPA" "$aks" '.workloadAutoScalerProfile.keda.enabled == true and .workloadAutoScalerProfile.verticalPodAutoscaler.enabled == true'

  # --- Node pools ---
  jq_ok "System pool: autoscaling + ephemeral OS disk" "$aks" \
    '.agentPoolProfiles[] | select(.name == "system") | .mode == "System" and .enableAutoScaling == true and .osDiskType == "Ephemeral"'
  jq_ok "User pool: autoscaling" "$aks" \
    '.agentPoolProfiles[] | select(.name == "user") | .mode == "User" and .enableAutoScaling == true'
  expect_ge "System pool availability zone count" "$(jv "$aks" '.agentPoolProfiles[] | select(.name == "system") | .availabilityZones | length')" 2

  # --- kubectl ---
  section "05-aks · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the 'Azure Kubernetes Service Cluster User Role' role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
      skip "Can't reach the private cluster's API server; skipping kubectl checks (re-run from a jump host or VPN inside the VNet)"
    else
      fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply 05-aks."
    fi
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  # An autoscaled pool never goes below minCount, so the baseline is the sum of each pool's
  # minimum node count (default: system 3 + user 3).
  want="$(jv "$aks" '[.agentPoolProfiles[] | if .enableAutoScaling == true then (.minCount // 0) else (.count // 0) end] | add')"
  expect_ge "Ready nodes (sum of per-pool minimum node counts)" "$ready" "${want:-1}"
  zones="$(jv "$nodes" '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')"
  expect_ge "Availability zones the nodes are spread across" "$zones" 2

  if [ "$(kubectl --request-timeout=20s auth can-i '*' '*' 2>/dev/null)" = "yes" ]; then
    pass "cluster-admin permission (Azure RBAC Cluster Admin)"
  else
    fail "No cluster-admin permission (role propagation can take up to 5 min; check grant_current_user_admin / admin_principal_ids)"
  fi

  if [ "$(jv "$aks" '(.ingressProfile.gatewayApi // .ingressProfile.gatewayAPI // {}).installation')" = "Standard" ]; then
    gc="$(kj get gatewayclass approuting-istio)"
    jq_ok "GatewayClass approuting-istio is Accepted" "$gc" '.status.conditions[]? | select(.type == "Accepted") | .status == "True"'
  else
    skip "Gateway API is off; skipping the GatewayClass check (enable_gateway_api = false)"
  fi

  pods="$(kj get pods -n kube-system)"
  for p in ama-logs ama-metrics cilium coredns; do
    jq_ok "kube-system: $p pod Running" "$pods" "[.items[] | select((.metadata.name | startswith(\"$p\")) and .status.phase == \"Running\")] | length >= 1"
  done
  bad="$(kj get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded)"
  jq_warn "No pods other than Running/Completed" "$bad" '(.items | length) == 0'
}

# You can also run it directly (scripts/verify/05-aks.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
