#!/usr/bin/env bash
# Lab 03 verification: checks that the VNet · subnets · NSGs · NAT Gateway · Private DNS were created as designed (read-only).
#   AWS comparison: VPC + subnets + Security Group/NACL + NAT Gateway + Route 53 private hosted zone
# Usage: scripts/verify.sh 03-network
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg vnet_name nat_ip vnet sn nat natsku pips zones zone links rules r
  rg="$(tf_out 03-network resource_group_name)"
  vnet_name="$(tf_out 03-network vnet_name)"
  nat_ip="$(tf_out 03-network nat_gateway_public_ip)"

  section "03-network · VNet (${vnet_name:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 03-network?"
    return
  fi

  vnet="$(azj network vnet show -g "$rg" -n "$vnet_name")"
  if [ -z "$vnet" ]; then
    fail "VNet not found: $vnet_name"
    return
  fi
  expect_set "Address space" "$(jv "$vnet" '.addressSpace.addressPrefixes | join(",")')"

  # Azure subnets aren't tied to an AZ; they span the whole region (in AWS, each subnet is pinned to an AZ).
  for sn in snet-aks-nodes snet-aks-apiserver snet-ingress snet-private-endpoints; do
    jq_ok "Subnet $sn exists" "$vnet" "[.subnets[] | select(.name == \"$sn\")] | length == 1"
  done
  jq_ok "API server subnet is delegated to managedClusters (API Server VNet Integration)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-apiserver") | .delegations | any(.serviceName == "Microsoft.ContainerService/managedClusters")'
  jq_ok "NAT Gateway attached to the node subnet (static egress)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .natGateway.id != null'
  jq_ok "Default outbound access disabled on the node subnet" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .defaultOutboundAccess == false'
  for sn in snet-aks-nodes snet-ingress snet-private-endpoints; do
    jq_ok "NSG attached: $sn" "$vnet" ".subnets[] | select(.name == \"$sn\") | .networkSecurityGroup.id != null"
  done

  # AKS doesn't modify an NSG attached to the subnet, so the node NSG's inbound allow rules
  # must be the ones Terraform created.
  rules="$(nodes_nsg_rules "$rg")"
  if [ -z "$rules" ]; then
    fail "Can't read the rules of the node subnet NSG (…-aks-nodes)"
  else
    for r in AllowNodesToPods AllowPodsToPods AllowApiServerToCluster; do
      jq_ok "Node NSG inbound allow: $r (Azure CNI Overlay / API Server VNet Integration)" "$rules" \
        "any(.[]; .name == \"$r\" and .direction == \"Inbound\" and .access == \"Allow\")"
    done
    # If gateway_allowed_source_prefixes = [] (internal Gateway only), it's normal for this rule to be absent.
    jq_warn "Node NSG inbound allow: AllowGatewayHttpHttps (public Gateway 80/443. Fine if you only use an internal Gateway)" "$rules" \
      'any(.[]; .name == "AllowGatewayHttpHttps" and .direction == "Inbound" and .access == "Allow")'
  fi

  nat="$(azj network nat gateway list -g "$rg")"
  natsku="$(jv "$nat" '.[0].sku.name')" # nat_gateway_sku variable: StandardV2 (default) / Standard
  case "$natsku" in
    StandardV2) pass "NAT Gateway SKU = StandardV2 (zone-redundant)" ;;
    Standard) warn "NAT Gateway SKU = Standard (not zone-redundant. Use it only in regions that don't support StandardV2)" ;;
    *) fail "NAT Gateway SKU: expected StandardV2 or Standard / actual '${natsku:-(none)}'" ;;
  esac
  pips="$(azj network public-ip list -g "$rg")"
  expect_eq "NAT public IP = terraform output" "$(jv "$pips" '[.[] | select(.name | startswith("pip-ng-"))][0].ipAddress')" "$nat_ip"

  # The Private DNS Zones for Private Endpoints must be linked to this VNet so that the names resolve to private IPs.
  zones="$(az network private-dns zone list -g "$rg" --query '[].name' -o tsv 2>/dev/null)"
  for zone in privatelink.azurecr.io privatelink.vaultcore.azure.net; do
    if printf '%s\n' "$zones" | grep -qx "$zone"; then
      links="$(azj network private-dns link vnet list -g "$rg" -z "$zone")"
      jq_ok "Private DNS Zone $zone linked to the VNet" "$links" "any(.[]; .virtualNetwork.id | endswith(\"/$vnet_name\"))"
    else
      fail "Private DNS Zone not found: $zone"
    fi
  done
}

# You can also run it directly (scripts/verify/03-network.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
